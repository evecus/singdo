package auth

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type Session struct {
	Token     string
	ExpiresAt time.Time
}

type Manager struct {
	dataDir  string
	mu       sync.RWMutex
	sessions map[string]Session
	creds    Credentials
}

func New(dataDir string) *Manager {
	m := &Manager{
		dataDir:  dataDir,
		sessions: make(map[string]Session),
		creds:    Credentials{Username: "admin", Password: "admin"},
	}
	m.load()
	return m
}

func (m *Manager) credFile() string {
	return filepath.Join(m.dataDir, "credentials.json")
}

func (m *Manager) load() {
	data, err := os.ReadFile(m.credFile())
	if err != nil {
		return
	}
	json.Unmarshal(data, &m.creds)
}

func (m *Manager) save() error {
	data, _ := json.MarshalIndent(m.creds, "", "  ")
	return os.WriteFile(m.credFile(), data, 0600)
}

func (m *Manager) Login(username, password string) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if username != m.creds.Username || password != m.creds.Password {
		return "", false
	}
	token := randomToken()
	m.sessions[token] = Session{Token: token, ExpiresAt: time.Now().Add(24 * time.Hour)}
	return token, true
}

func (m *Manager) Validate(token string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[token]
	if !ok {
		return false
	}
	return time.Now().Before(s.ExpiresAt)
}

func (m *Manager) Logout(token string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.sessions, token)
}

func (m *Manager) UpdateCredentials(username, password string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.creds.Username = username
	m.creds.Password = password
	return m.save()
}

func (m *Manager) GetUsername() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.creds.Username
}

func randomToken() string {
	b := make([]byte, 32)
	rand.Read(b)
	return hex.EncodeToString(b)
}
