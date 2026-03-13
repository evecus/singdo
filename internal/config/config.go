package config

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const SingBoxBin = "/usr/sing-box"
const SingBoxConfig = "/opt/sing-box/config.json"
const SingBoxConfigDir = "/opt/sing-box"

// ── x25519 pure-Go (RFC 7748) ──────────────────────────────────────────────

func x25519ScalarMult(k, u []byte) []byte {
	const P = uint64(0x7ffffffffffed) // just need modular arithmetic via big.Int
	// Use Go's math/big for the full 255-bit field arithmetic
	p := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 255), big.NewInt(19))
	a24 := big.NewInt(121665)

	toInt := func(b []byte) *big.Int {
		// little-endian
		c := make([]byte, 32)
		copy(c, b)
		// reverse for big.Int (big-endian)
		for i, j := 0, 31; i < j; i, j = i+1, j-1 {
			c[i], c[j] = c[j], c[i]
		}
		return new(big.Int).SetBytes(c)
	}
	fromInt := func(n *big.Int) []byte {
		b := n.Bytes()
		// big-endian → little-endian, padded to 32
		out := make([]byte, 32)
		for i, v := range b {
			out[len(b)-1-i] = v
		}
		return out
	}
	mod := func(n *big.Int) *big.Int { return new(big.Int).Mod(n, p) }
	add := func(a, b *big.Int) *big.Int { return mod(new(big.Int).Add(a, b)) }
	sub := func(a, b *big.Int) *big.Int { return mod(new(big.Int).Sub(a, b)) }
	mul := func(a, b *big.Int) *big.Int { return mod(new(big.Int).Mul(a, b)) }
	sq  := func(a *big.Int) *big.Int   { return mul(a, a) }
	inv := func(a *big.Int) *big.Int   {
		exp := new(big.Int).Sub(p, big.NewInt(2))
		return new(big.Int).Exp(a, exp, p)
	}

	_ = P // suppress unused

	kk := make([]byte, 32)
	copy(kk, k)
	kk[0] &= 248
	kk[31] &= 127
	kk[31] |= 64

	x1 := toInt(u)
	x2 := big.NewInt(1)
	z2 := big.NewInt(0)
	x3 := toInt(u)
	z3 := big.NewInt(1)
	swap := 0

	for t := 254; t >= 0; t-- {
		byteIdx := t / 8
		bit := int((kk[byteIdx] >> uint(t%8)) & 1)
		swap ^= bit
		if swap == 1 {
			x2, x3 = x3, x2
			z2, z3 = z3, z2
		}
		swap = bit

		A  := add(x2, z2)
		AA := sq(A)
		B  := sub(x2, z2)
		BB := sq(B)
		E  := sub(AA, BB)
		C  := add(x3, z3)
		D  := sub(x3, z3)
		DA := mul(D, A)
		CB := mul(C, B)
		x3 = sq(add(DA, CB))
		z3 = mul(x1, sq(sub(DA, CB)))
		x2 = mul(AA, BB)
		z2 = mul(E, add(AA, mul(a24, E)))
	}
	if swap == 1 {
		x2, x3 = x3, x2
		z2, z3 = z3, z2
	}
	_ = x3
	_ = z3
	result := mul(x2, inv(z2))
	return fromInt(result)
}

// x25519Basepoint is the standard Curve25519 base point u=9
var x25519Basepoint = func() []byte {
	b := make([]byte, 32)
	b[0] = 9
	return b
}()

// GenerateRealityKeyPair returns (privateKey, publicKey) base64url-encoded
func GenerateRealityKeyPair() (string, string, error) {
	priv := make([]byte, 32)
	if _, err := rand.Read(priv); err != nil {
		return "", "", err
	}
	// Clamp per RFC 7748
	priv[0] &= 248
	priv[31] &= 127
	priv[31] |= 64

	pub := x25519ScalarMult(priv, x25519Basepoint)
	privB64 := base64.RawURLEncoding.EncodeToString(priv)
	pubB64  := base64.RawURLEncoding.EncodeToString(pub)
	return privB64, pubB64, nil
}

// ── Types ──────────────────────────────────────────────────────────────────────

type TLSConfig struct {
	Enabled    bool   `json:"enabled"`
	Mode       string `json:"mode"` // "self-signed", "custom-path", "inline"
	CertPath   string `json:"cert_path,omitempty"`
	KeyPath    string `json:"key_path,omitempty"`
	CertPEM    string `json:"cert_pem,omitempty"`
	KeyPEM     string `json:"key_pem,omitempty"`
	ServerName string `json:"server_name,omitempty"`
}

type RealityConfig struct {
	Enabled    bool     `json:"enabled"`
	PrivateKey string   `json:"private_key"`
	PublicKey  string   `json:"public_key"`
	ShortIDs   []string `json:"short_id"`
	ServerName string   `json:"server_name"`
	ServerPort int      `json:"server_port"`
}

type Inbound struct {
	ID        string        `json:"id"`
	Tag       string        `json:"tag"`
	Type      string        `json:"type"`
	Port      int           `json:"port"`
	UUID      string        `json:"uuid,omitempty"`
	Password  string        `json:"password,omitempty"`
	Method    string        `json:"method,omitempty"`
	Flow      string        `json:"flow,omitempty"`
	AlterId   int           `json:"alter_id,omitempty"`
	Transport string        `json:"transport,omitempty"`
	WsPath    string        `json:"ws_path,omitempty"`
	WsHost    string        `json:"ws_host,omitempty"`
	GrpcSvc   string        `json:"grpc_svc,omitempty"`
	TLS       TLSConfig     `json:"tls"`
	Reality   RealityConfig `json:"reality"`
	UpMbps    int           `json:"up_mbps,omitempty"`
	DownMbps  int           `json:"down_mbps,omitempty"`
	CC        string        `json:"cc,omitempty"`
}

type AppConfig struct {
	Inbounds []Inbound `json:"inbounds"`
}

type Manager struct {
	dataDir string
	mu      sync.RWMutex
	cfg     AppConfig
}

func New(dataDir string) *Manager {
	m := &Manager{dataDir: dataDir}
	m.load()
	return m
}

func (m *Manager) configFile() string {
	return filepath.Join(m.dataDir, "panel_config.json")
}

func (m *Manager) load() {
	data, err := os.ReadFile(m.configFile())
	if err != nil {
		return
	}
	json.Unmarshal(data, &m.cfg)
}

func (m *Manager) save() error {
	data, _ := json.MarshalIndent(m.cfg, "", "  ")
	return os.WriteFile(m.configFile(), data, 0644)
}

func (m *Manager) GetInbounds() []Inbound {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := make([]Inbound, len(m.cfg.Inbounds))
	copy(result, m.cfg.Inbounds)
	return result
}

func (m *Manager) AddInbound(ib Inbound) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	ib.ID = randomID()
	m.cfg.Inbounds = append(m.cfg.Inbounds, ib)
	return m.save()
}

func (m *Manager) DeleteInbound(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, ib := range m.cfg.Inbounds {
		if ib.ID == id {
			m.cfg.Inbounds = append(m.cfg.Inbounds[:i], m.cfg.Inbounds[i+1:]...)
			return m.save()
		}
	}
	return fmt.Errorf("inbound %s not found", id)
}

func (m *Manager) UpdateInbound(ib Inbound) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, existing := range m.cfg.Inbounds {
		if existing.ID == ib.ID {
			m.cfg.Inbounds[i] = ib
			return m.save()
		}
	}
	return fmt.Errorf("inbound %s not found", ib.ID)
}

// ExportSingBoxConfig generates the actual sing-box config.json
func (m *Manager) ExportSingBoxConfig() ([]byte, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	type RawInbound = map[string]interface{}
	inbounds := []RawInbound{}

	for _, ib := range m.cfg.Inbounds {
		raw, err := buildSingBoxInbound(ib)
		if err != nil {
			return nil, fmt.Errorf("inbound %s: %w", ib.Tag, err)
		}
		inbounds = append(inbounds, raw)
	}

	out := map[string]interface{}{
		"log": map[string]interface{}{"level": "info", "timestamp": true},
		"inbounds": inbounds,
		"outbounds": []map[string]interface{}{
			{"type": "direct", "tag": "direct"},
			{"type": "block", "tag": "block"},
		},
	}
	return json.MarshalIndent(out, "", "  ")
}

func (m *Manager) WriteSingBoxConfig() error {
	data, err := m.ExportSingBoxConfig()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(SingBoxConfigDir, 0755); err != nil {
		return err
	}
	return os.WriteFile(SingBoxConfig, data, 0644)
}

func buildSingBoxInbound(ib Inbound) (map[string]interface{}, error) {
	base := map[string]interface{}{
		"type":        ib.Type,
		"tag":         ib.Tag,
		"listen":      "0.0.0.0",
		"listen_port": ib.Port,
	}
	switch ib.Type {
	case "vless":
		users := []map[string]interface{}{{"uuid": ib.UUID}}
		if ib.Flow != "" {
			users[0]["flow"] = ib.Flow
		}
		base["users"] = users
		addTransport(base, ib)
		addTLS(base, ib)
	case "vmess":
		base["users"] = []map[string]interface{}{{"uuid": ib.UUID, "alterId": ib.AlterId}}
		addTransport(base, ib)
		addTLS(base, ib)
	case "trojan":
		base["users"] = []map[string]interface{}{{"password": ib.Password}}
		addTransport(base, ib)
		addTLS(base, ib)
	case "shadowsocks":
		base["method"] = ib.Method
		base["password"] = ib.Password
		addTLS(base, ib)
	case "hysteria2":
		base["users"] = []map[string]interface{}{{"password": ib.Password}}
		if ib.UpMbps > 0 {
			base["up_mbps"] = ib.UpMbps
		}
		if ib.DownMbps > 0 {
			base["down_mbps"] = ib.DownMbps
		}
		addTLS(base, ib)
	case "tuic":
		base["users"] = []map[string]interface{}{{"uuid": ib.UUID, "password": ib.Password}}
		if ib.CC != "" {
			base["congestion_control"] = ib.CC
		}
		addTLS(base, ib)
	case "naive":
		base["users"] = []map[string]interface{}{{"username": ib.UUID, "password": ib.Password}}
		addTLS(base, ib)
	}
	return base, nil
}

func addTransport(base map[string]interface{}, ib Inbound) {
	if ib.Transport == "" || ib.Transport == "tcp" {
		return
	}
	t := map[string]interface{}{"type": ib.Transport}
	if ib.Transport == "ws" {
		if ib.WsPath != "" {
			t["path"] = ib.WsPath
		}
		if ib.WsHost != "" {
			t["headers"] = map[string]string{"Host": ib.WsHost}
		}
	}
	if ib.Transport == "grpc" && ib.GrpcSvc != "" {
		t["service_name"] = ib.GrpcSvc
	}
	base["transport"] = t
}

func addTLS(base map[string]interface{}, ib Inbound) {
	if ib.Reality.Enabled {
		tls := map[string]interface{}{
			"enabled": true,
			"reality": map[string]interface{}{
				"enabled": true,
				"handshake": map[string]interface{}{
					"server":      ib.Reality.ServerName,
					"server_port": ib.Reality.ServerPort,
				},
				"private_key": ib.Reality.PrivateKey,
				"short_id":    ib.Reality.ShortIDs,
			},
		}
		base["tls"] = tls
		return
	}
	if !ib.TLS.Enabled {
		return
	}
	tls := map[string]interface{}{"enabled": true}
	if ib.TLS.ServerName != "" {
		tls["server_name"] = ib.TLS.ServerName
	}
	switch ib.TLS.Mode {
	case "custom-path":
		tls["certificate_path"] = ib.TLS.CertPath
		tls["key_path"] = ib.TLS.KeyPath
	case "inline":
		tls["certificate"] = ib.TLS.CertPEM
		tls["key"] = ib.TLS.KeyPEM
	case "self-signed":
		certPEM, keyPEM, err := generateSelfSignedCert(ib.TLS.ServerName)
		if err == nil {
			tls["certificate"] = certPEM
			tls["key"] = keyPEM
		}
	}
	base["tls"] = tls
}

// ── Generators ────────────────────────────────────────────────────────────────

func GenerateShortID() string {
	b := make([]byte, 4)
	rand.Read(b)
	return fmt.Sprintf("%x", b)
}

func GenerateUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func GeneratePassword() string {
	b := make([]byte, 24)
	rand.Read(b)
	return base64.StdEncoding.EncodeToString(b)
}

func generateSelfSignedCert(host string) (string, string, error) {
	if host == "" {
		host = "localhost"
	}
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", err
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: host},
		DNSNames:     []string{host},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour * 10),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	certDER, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return "", "", err
	}
	certPEM := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER}))
	privDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return "", "", err
	}
	keyPEM := string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: privDER}))
	return certPEM, keyPEM, nil
}

func GenerateSelfSignedCert(host string) (string, string, error) {
	return generateSelfSignedCert(host)
}

// ── Backup / Restore ──────────────────────────────────────────────────────────

func (m *Manager) Backup() ([]byte, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	type BackupData struct {
		Version  int       `json:"version"`
		At       time.Time `json:"at"`
		Inbounds []Inbound `json:"inbounds"`
	}
	b := BackupData{Version: 1, At: time.Now(), Inbounds: m.cfg.Inbounds}
	return json.MarshalIndent(b, "", "  ")
}

func (m *Manager) Restore(data []byte) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	type BackupData struct {
		Inbounds []Inbound `json:"inbounds"`
	}
	var b BackupData
	if err := json.Unmarshal(data, &b); err != nil {
		return err
	}
	m.cfg.Inbounds = b.Inbounds
	return m.save()
}

func randomID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return fmt.Sprintf("%x", b)
}
