package main

import (
	"embed"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"singpanel/internal/api"
	"singpanel/internal/auth"
	"singpanel/internal/config"
)

//go:embed web/dist
var webFS embed.FS

var version = "1.0.0"

func main() {
	portFlag := flag.Int("port", 9009, "Web panel port")
	dataDirFlag := flag.String("data", "", "Data directory (default: ./data next to binary)")
	verFlag := flag.Bool("version", false, "Print version")
	flag.Parse()

	if *verFlag {
		fmt.Printf("sing-box panel v%s\n", version)
		os.Exit(0)
	}

	dataDir := *dataDirFlag
	if dataDir == "" {
		exe, err := os.Executable()
		if err != nil {
			log.Fatal(err)
		}
		dataDir = filepath.Join(filepath.Dir(exe), "data")
	}

	if err := os.MkdirAll(dataDir, 0755); err != nil {
		log.Fatalf("Cannot create data dir: %v", err)
	}
	os.MkdirAll("/opt/sing-box", 0755)

	cfg := config.New(dataDir)
	authMgr := auth.New(dataDir)
	server := api.New(cfg, authMgr, webFS, dataDir, *portFlag)

	log.Printf("sing-box panel v%s | port :%d | data: %s", version, *portFlag, dataDir)
	log.Printf("Access: http://localhost:%d", *portFlag)
	if err := server.Start(); err != nil {
		log.Fatal(err)
	}
}
