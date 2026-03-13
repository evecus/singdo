package system

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

const SingBoxBin = "/usr/sing-box"

type Status struct {
	Installed  bool   `json:"installed"`
	Version    string `json:"version"`
	Running    bool   `json:"running"`
	SystemdOn  bool   `json:"systemd_enabled"`
	BinPath    string `json:"bin_path"`
	ConfigPath string `json:"config_path"`
}

func GetStatus() Status {
	s := Status{BinPath: SingBoxBin, ConfigPath: "/opt/sing-box/config.json"}
	if _, err := os.Stat(SingBoxBin); err == nil {
		s.Installed = true
		out, _ := exec.Command(SingBoxBin, "version").Output()
		s.Version = strings.TrimSpace(string(out))
	}
	out, err := exec.Command("systemctl", "is-active", "sing-box").Output()
	s.Running = err == nil && strings.TrimSpace(string(out)) == "active"
	out2, err2 := exec.Command("systemctl", "is-enabled", "sing-box").Output()
	s.SystemdOn = err2 == nil && strings.Contains(string(out2), "enabled")
	return s
}

func StartService() error {
	return exec.Command("systemctl", "start", "sing-box").Run()
}

func StopService() error {
	return exec.Command("systemctl", "stop", "sing-box").Run()
}

func RestartService() error {
	return exec.Command("systemctl", "restart", "sing-box").Run()
}

func EnableService() error {
	return exec.Command("systemctl", "enable", "sing-box").Run()
}

func DisableService() error {
	return exec.Command("systemctl", "disable", "sing-box").Run()
}

func RegisterSystemd() error {
	unit := `[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/opt/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/sing-box run -c /opt/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
`
	if err := os.WriteFile("/etc/systemd/system/sing-box.service", []byte(unit), 0644); err != nil {
		return fmt.Errorf("write unit: %w", err)
	}
	if err := exec.Command("systemctl", "daemon-reload").Run(); err != nil {
		return fmt.Errorf("daemon-reload: %w", err)
	}
	return nil
}

func DownloadSingBox(version string, progress func(string)) error {
	arch := runtime.GOARCH
	// map go arch to sing-box release arch
	archMap := map[string]string{
		"amd64": "amd64",
		"arm64": "arm64",
	}
	sbArch, ok := archMap[arch]
	if !ok {
		sbArch = arch
	}

	var url string
	if version == "" || version == "latest" {
		// fetch latest release tag
		progress("Fetching latest version info...")
		resp, err := http.Get("https://api.github.com/repos/SagerNet/sing-box/releases/latest")
		if err != nil {
			return fmt.Errorf("fetch release info: %w", err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		// simple parse
		tag := extractJSON(string(body), "tag_name")
		if tag == "" {
			return fmt.Errorf("cannot determine latest version")
		}
		version = tag
		progress(fmt.Sprintf("Latest version: %s", version))
	}

	// Strip leading 'v' for directory name in download URL
	verNum := strings.TrimPrefix(version, "v")
	url = fmt.Sprintf(
		"https://github.com/SagerNet/sing-box/releases/download/%s/sing-box-%s-linux-%s.tar.gz",
		version, verNum, sbArch,
	)

	progress(fmt.Sprintf("Downloading from: %s", url))
	tmpFile, err := os.CreateTemp("", "sing-box-*.tar.gz")
	if err != nil {
		return err
	}
	defer os.Remove(tmpFile.Name())

	resp, err := http.Get(url)
	if err != nil {
		return fmt.Errorf("download: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download failed: HTTP %d", resp.StatusCode)
	}

	if _, err := io.Copy(tmpFile, resp.Body); err != nil {
		return fmt.Errorf("write temp: %w", err)
	}
	tmpFile.Close()

	progress("Extracting...")
	tmpDir, err := os.MkdirTemp("", "sing-box-extract-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpDir)

	cmd := exec.Command("tar", "-xzf", tmpFile.Name(), "-C", tmpDir, "--strip-components=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("extract: %w: %s", err, out)
	}

	// Find the sing-box binary in extracted dir
	extracted := tmpDir + "/sing-box"
	if _, err := os.Stat(extracted); err != nil {
		return fmt.Errorf("extracted binary not found at %s", extracted)
	}

	progress(fmt.Sprintf("Installing to %s...", SingBoxBin))
	// Stop service first if running
	exec.Command("systemctl", "stop", "sing-box").Run()

	if err := os.Rename(extracted, SingBoxBin); err != nil {
		// Try copy if rename fails (cross-device)
		if err2 := copyFile(extracted, SingBoxBin); err2 != nil {
			return fmt.Errorf("install binary: %w", err2)
		}
	}
	os.Chmod(SingBoxBin, 0755)
	progress("Done!")
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func extractJSON(s, key string) string {
	search := `"` + key + `": "`
	idx := strings.Index(s, search)
	if idx < 0 {
		return ""
	}
	rest := s[idx+len(search):]
	end := strings.Index(rest, `"`)
	if end < 0 {
		return ""
	}
	return rest[:end]
}

func GetLogs(n int) string {
	cmd := exec.Command("journalctl", "-u", "sing-box", "-n", fmt.Sprintf("%d", n), "--no-pager", "--output=short")
	out, _ := cmd.CombinedOutput()
	return string(out)
}
