package api

import (
	"archive/zip"
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"singpanel/internal/auth"
	"singpanel/internal/config"
	"singpanel/internal/system"
)

type Server struct {
	cfg     *config.Manager
	auth    *auth.Manager
	webFS   embed.FS
	dataDir string
	port    int

	// SSE for download progress
	progressMu      sync.Mutex
	progressClients map[string]chan string
}

func New(cfg *config.Manager, authMgr *auth.Manager, webFS embed.FS, dataDir string, port int) *Server {
	return &Server{
		cfg:             cfg,
		auth:            authMgr,
		webFS:           webFS,
		dataDir:         dataDir,
		port:            port,
		progressClients: make(map[string]chan string),
	}
}

func (s *Server) Start() error {
	mux := http.NewServeMux()

	// Auth
	mux.HandleFunc("/api/login", s.handleLogin)
	mux.HandleFunc("/api/logout", s.handleLogout)

	// Inbounds
	mux.HandleFunc("/api/inbounds", s.authMiddleware(s.handleInbounds))
	mux.HandleFunc("/api/inbounds/", s.authMiddleware(s.handleInboundItem))

	// Config export
	mux.HandleFunc("/api/export/singbox", s.authMiddleware(s.handleExportSingBox))
	mux.HandleFunc("/api/export/subscribe", s.authMiddleware(s.handleExportSubscribe))
	mux.HandleFunc("/api/apply", s.authMiddleware(s.handleApplyConfig))

	// Backup/Restore
	mux.HandleFunc("/api/backup", s.authMiddleware(s.handleBackup))
	mux.HandleFunc("/api/restore", s.authMiddleware(s.handleRestore))

	// System
	mux.HandleFunc("/api/system/status", s.authMiddleware(s.handleSystemStatus))
	mux.HandleFunc("/api/system/action", s.authMiddleware(s.handleSystemAction))
	mux.HandleFunc("/api/system/download", s.authMiddleware(s.handleDownload))
	mux.HandleFunc("/api/system/logs", s.authMiddleware(s.handleLogs))
	mux.HandleFunc("/api/system/progress", s.authMiddleware(s.handleProgress))

	// Generators
	mux.HandleFunc("/api/gen/uuid", s.authMiddleware(s.handleGenUUID))
	mux.HandleFunc("/api/gen/password", s.authMiddleware(s.handleGenPassword))
	mux.HandleFunc("/api/gen/reality", s.authMiddleware(s.handleGenReality))
	mux.HandleFunc("/api/gen/cert", s.authMiddleware(s.handleGenCert))
	mux.HandleFunc("/api/gen/shortid", s.authMiddleware(s.handleGenShortID))

	// Settings
	mux.HandleFunc("/api/settings", s.authMiddleware(s.handleSettings))

	// Static files
	subFS, err := fs.Sub(s.webFS, "web/dist")
	if err != nil {
		// fallback: serve from root
		subFS = s.webFS
	}
	fileServer := http.FileServer(http.FS(subFS))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// SPA fallback
		_, err := fs.Stat(subFS, strings.TrimPrefix(r.URL.Path, "/"))
		if err != nil || r.URL.Path == "/" {
			r.URL.Path = "/"
		}
		fileServer.ServeHTTP(w, r)
	})

	addr := fmt.Sprintf(":%d", s.port)
	return http.ListenAndServe(addr, mux)
}

// ─── Middleware ───────────────────────────────────────────────────────────────

func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("X-Token")
		if token == "" {
			cookie, err := r.Cookie("token")
			if err == nil {
				token = cookie.Value
			}
		}
		if !s.auth.Validate(token) {
			jsonError(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// ─── Auth ─────────────────────────────────────────────────────────────────────

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	token, ok := s.auth.Login(req.Username, req.Password)
	if !ok {
		jsonError(w, "Invalid credentials", http.StatusUnauthorized)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     "token",
		Value:    token,
		Path:     "/",
		MaxAge:   86400,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	jsonOK(w, map[string]string{"token": token})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	token := r.Header.Get("X-Token")
	if token == "" {
		if c, err := r.Cookie("token"); err == nil {
			token = c.Value
		}
	}
	s.auth.Logout(token)
	http.SetCookie(w, &http.Cookie{Name: "token", Value: "", MaxAge: -1, Path: "/"})
	jsonOK(w, map[string]string{"status": "ok"})
}

// ─── Inbounds ─────────────────────────────────────────────────────────────────

func (s *Server) handleInbounds(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		jsonOK(w, s.cfg.GetInbounds())
	case http.MethodPost:
		var ib config.Inbound
		if err := json.NewDecoder(r.Body).Decode(&ib); err != nil {
			jsonError(w, err.Error(), http.StatusBadRequest)
			return
		}
		if err := s.cfg.AddInbound(ib); err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]string{"status": "ok"})
	default:
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) handleInboundItem(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/inbounds/")
	switch r.Method {
	case http.MethodPut:
		var ib config.Inbound
		if err := json.NewDecoder(r.Body).Decode(&ib); err != nil {
			jsonError(w, err.Error(), http.StatusBadRequest)
			return
		}
		ib.ID = id
		if err := s.cfg.UpdateInbound(ib); err != nil {
			jsonError(w, err.Error(), http.StatusNotFound)
			return
		}
		jsonOK(w, map[string]string{"status": "ok"})
	case http.MethodDelete:
		if err := s.cfg.DeleteInbound(id); err != nil {
			jsonError(w, err.Error(), http.StatusNotFound)
			return
		}
		jsonOK(w, map[string]string{"status": "ok"})
	default:
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// ─── Export ───────────────────────────────────────────────────────────────────

func (s *Server) handleExportSingBox(w http.ResponseWriter, r *http.Request) {
	data, err := s.cfg.ExportSingBoxConfig()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Disposition", "attachment; filename=config.json")
	w.Write(data)
}

func (s *Server) handleExportSubscribe(w http.ResponseWriter, r *http.Request) {
	host := r.URL.Query().Get("host")
	if host == "" {
		host = r.Host
		// strip port from host if present
		if idx := strings.LastIndex(host, ":"); idx >= 0 {
			host = host[:idx]
		}
	}
	inbounds := s.cfg.GetInbounds()
	links := buildShareLinks(inbounds, host)
	content := strings.Join(links, "\n")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", "attachment; filename=subscribe.txt")
	w.Write([]byte(content))
}

func (s *Server) handleApplyConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := s.cfg.WriteSingBoxConfig(); err != nil {
		jsonError(w, "write config: "+err.Error(), http.StatusInternalServerError)
		return
	}
	// reload if running
	system.RestartService()
	jsonOK(w, map[string]string{"status": "ok", "message": "Config applied and service restarted"})
}

// ─── Backup / Restore ─────────────────────────────────────────────────────────

func (s *Server) handleBackup(w http.ResponseWriter, r *http.Request) {
	data, err := s.cfg.Backup()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	// Bundle as zip
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	f, _ := zw.Create("singpanel_backup.json")
	f.Write(data)
	zw.Close()

	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="singpanel_backup_%s.zip"`, time.Now().Format("20060102_150405")))
	w.Write(buf.Bytes())
}

func (s *Server) handleRestore(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	r.ParseMultipartForm(10 << 20)
	file, _, err := r.FormFile("file")
	if err != nil {
		// try raw JSON body
		body, _ := io.ReadAll(r.Body)
		if len(body) == 0 {
			jsonError(w, "no file provided", http.StatusBadRequest)
			return
		}
		if err := s.cfg.Restore(body); err != nil {
			jsonError(w, err.Error(), http.StatusBadRequest)
			return
		}
		jsonOK(w, map[string]string{"status": "ok"})
		return
	}
	defer file.Close()
	raw, _ := io.ReadAll(file)

	// Try as zip first
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err == nil {
		for _, f := range zr.File {
			if strings.HasSuffix(f.Name, ".json") {
				rc, _ := f.Open()
				data, _ := io.ReadAll(rc)
				rc.Close()
				if err := s.cfg.Restore(data); err != nil {
					jsonError(w, err.Error(), http.StatusBadRequest)
					return
				}
				jsonOK(w, map[string]string{"status": "ok"})
				return
			}
		}
	}
	// Try raw JSON
	if err := s.cfg.Restore(raw); err != nil {
		jsonError(w, err.Error(), http.StatusBadRequest)
		return
	}
	jsonOK(w, map[string]string{"status": "ok"})
}

// ─── System ───────────────────────────────────────────────────────────────────

func (s *Server) handleSystemStatus(w http.ResponseWriter, r *http.Request) {
	jsonOK(w, system.GetStatus())
}

func (s *Server) handleSystemAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Action string `json:"action"`
	}
	json.NewDecoder(r.Body).Decode(&req)

	var err error
	switch req.Action {
	case "start":
		err = system.StartService()
	case "stop":
		err = system.StopService()
	case "restart":
		err = system.RestartService()
	case "enable":
		err = system.EnableService()
	case "disable":
		err = system.DisableService()
	case "register":
		err = system.RegisterSystemd()
	default:
		jsonError(w, "unknown action: "+req.Action, http.StatusBadRequest)
		return
	}
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"status": "ok"})
}

func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Version string `json:"version"`
	}
	json.NewDecoder(r.Body).Decode(&req)

	clientID := fmt.Sprintf("%d", time.Now().UnixNano())
	ch := make(chan string, 20)
	s.progressMu.Lock()
	s.progressClients[clientID] = ch
	s.progressMu.Unlock()

	go func() {
		defer func() {
			s.progressMu.Lock()
			delete(s.progressClients, clientID)
			s.progressMu.Unlock()
			close(ch)
		}()
		err := system.DownloadSingBox(req.Version, func(msg string) {
			log.Printf("[download] %s", msg)
			select {
			case ch <- msg:
			default:
			}
		})
		if err != nil {
			ch <- "ERROR: " + err.Error()
		} else {
			ch <- "DONE"
		}
	}()

	jsonOK(w, map[string]string{"client_id": clientID})
}

func (s *Server) handleProgress(w http.ResponseWriter, r *http.Request) {
	clientID := r.URL.Query().Get("id")
	s.progressMu.Lock()
	ch, ok := s.progressClients[clientID]
	s.progressMu.Unlock()
	if !ok {
		jsonError(w, "no such download", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	flusher, _ := w.(http.Flusher)

	for msg := range ch {
		fmt.Fprintf(w, "data: %s\n\n", msg)
		if flusher != nil {
			flusher.Flush()
		}
		if msg == "DONE" || strings.HasPrefix(msg, "ERROR:") {
			return
		}
	}
}

func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request) {
	logs := system.GetLogs(200)
	jsonOK(w, map[string]string{"logs": logs})
}

// ─── Generators ───────────────────────────────────────────────────────────────

func (s *Server) handleGenUUID(w http.ResponseWriter, r *http.Request) {
	jsonOK(w, map[string]string{"uuid": config.GenerateUUID()})
}

func (s *Server) handleGenPassword(w http.ResponseWriter, r *http.Request) {
	jsonOK(w, map[string]string{"password": config.GeneratePassword()})
}

func (s *Server) handleGenReality(w http.ResponseWriter, r *http.Request) {
	priv, pub, err := config.GenerateRealityKeyPair()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"private_key": priv, "public_key": pub})
}

func (s *Server) handleGenCert(w http.ResponseWriter, r *http.Request) {
	host := r.URL.Query().Get("host")
	cert, key, err := config.GenerateSelfSignedCert(host)
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"cert": cert, "key": key})
}

func (s *Server) handleGenShortID(w http.ResponseWriter, r *http.Request) {
	jsonOK(w, map[string]string{"short_id": config.GenerateShortID()})
}

// ─── Settings ─────────────────────────────────────────────────────────────────

func (s *Server) handleSettings(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		jsonOK(w, map[string]string{"username": s.auth.GetUsername()})
	case http.MethodPost:
		var req struct {
			Username string `json:"username"`
			Password string `json:"password"`
		}
		json.NewDecoder(r.Body).Decode(&req)
		if req.Username == "" || req.Password == "" {
			jsonError(w, "username and password required", http.StatusBadRequest)
			return
		}
		if err := s.auth.UpdateCredentials(req.Username, req.Password); err != nil {
			jsonError(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]string{"status": "ok"})
	default:
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func jsonOK(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// ─── Share Link Builder ───────────────────────────────────────────────────────

func buildShareLinks(inbounds []config.Inbound, server string) []string {
	var links []string
	for _, ib := range inbounds {
		link := buildLink(ib, server)
		if link != "" {
			links = append(links, link)
		}
	}
	return links
}

func buildLink(ib config.Inbound, server string) string {
	name := urlEncode(ib.Tag)
	switch ib.Type {
	case "vless":
		params := "encryption=none"
		if ib.Flow != "" {
			params += "&flow=" + ib.Flow
		}
		if ib.Reality.Enabled {
			params += "&security=reality"
			params += "&pbk=" + ib.Reality.PublicKey
			if len(ib.Reality.ShortIDs) > 0 {
				params += "&sid=" + ib.Reality.ShortIDs[0]
			}
			if ib.Reality.ServerName != "" {
				params += "&sni=" + ib.Reality.ServerName + "&fp=chrome"
			}
		} else if ib.TLS.Enabled {
			params += "&security=tls"
			if ib.TLS.ServerName != "" {
				params += "&sni=" + ib.TLS.ServerName
			}
		}
		params += buildTransportParams(ib)
		return fmt.Sprintf("vless://%s@%s:%d?%s#%s", ib.UUID, server, ib.Port, params, name)

	case "vmess":
		net := "tcp"
		if ib.Transport != "" && ib.Transport != "tcp" {
			net = ib.Transport
		}
		tls := ""
		if ib.TLS.Enabled {
			tls = "tls"
		}
		obj := map[string]interface{}{
			"v": "2", "ps": ib.Tag, "add": server, "port": ib.Port,
			"id": ib.UUID, "aid": ib.AlterId, "scy": "auto",
			"net": net, "type": "none", "host": ib.WsHost,
			"path": ib.WsPath, "tls": tls, "sni": ib.TLS.ServerName,
		}
		b, _ := json.Marshal(obj)
		return "vmess://" + b64url(string(b))

	case "trojan":
		params := "security=tls"
		if ib.TLS.ServerName != "" {
			params += "&sni=" + ib.TLS.ServerName
		}
		params += buildTransportParams(ib)
		return fmt.Sprintf("trojan://%s@%s:%d?%s#%s", ib.Password, server, ib.Port, params, name)

	case "shadowsocks":
		userinfo := b64url(ib.Method + ":" + ib.Password)
		return fmt.Sprintf("ss://%s@%s:%d#%s", userinfo, server, ib.Port, name)

	case "hysteria2":
		params := ""
		if ib.TLS.ServerName != "" {
			params = "sni=" + ib.TLS.ServerName
		}
		link := fmt.Sprintf("hysteria2://%s@%s:%d", ib.Password, server, ib.Port)
		if params != "" {
			link += "?" + params
		}
		return link + "#" + name

	case "tuic":
		params := ""
		if ib.CC != "" {
			params = "congestion_control=" + ib.CC
		}
		if ib.TLS.ServerName != "" {
			if params != "" {
				params += "&"
			}
			params += "sni=" + ib.TLS.ServerName
		}
		link := fmt.Sprintf("tuic://%s:%s@%s:%d", ib.UUID, ib.Password, server, ib.Port)
		if params != "" {
			link += "?" + params
		}
		return link + "#" + name
	}
	return ""
}

func buildTransportParams(ib config.Inbound) string {
	if ib.Transport == "" || ib.Transport == "tcp" {
		return "&type=tcp"
	}
	p := "&type=" + ib.Transport
	if ib.Transport == "ws" {
		if ib.WsPath != "" {
			p += "&path=" + urlEncode(ib.WsPath)
		}
		if ib.WsHost != "" {
			p += "&host=" + ib.WsHost
		}
	}
	if ib.Transport == "grpc" && ib.GrpcSvc != "" {
		p += "&serviceName=" + ib.GrpcSvc
	}
	return p
}

func b64url(s string) string {
	b := []byte(s)
	var buf strings.Builder
	for i := 0; i < len(b); i += 3 {
		var v uint32
		n := 0
		for j := 0; j < 3 && i+j < len(b); j++ {
			v |= uint32(b[i+j]) << (16 - uint(j)*8)
			n++
		}
		buf.WriteByte(encChar((v >> 18) & 0x3f))
		buf.WriteByte(encChar((v >> 12) & 0x3f))
		if n > 1 {
			buf.WriteByte(encChar((v >> 6) & 0x3f))
		} else {
			buf.WriteByte('=')
		}
		if n > 2 {
			buf.WriteByte(encChar(v & 0x3f))
		} else {
			buf.WriteByte('=')
		}
	}
	return buf.String()
}

func encChar(v uint32) byte {
	const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	return chars[v]
}

func urlEncode(s string) string {
	var buf strings.Builder
	for _, b := range []byte(s) {
		if isUnreserved(b) {
			buf.WriteByte(b)
		} else {
			buf.WriteString(fmt.Sprintf("%%%02X", b))
		}
	}
	return buf.String()
}

func isUnreserved(b byte) bool {
	return (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z') || (b >= '0' && b <= '9') ||
		b == '-' || b == '_' || b == '.' || b == '~'
}
