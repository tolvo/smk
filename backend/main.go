package main

import (
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"math/rand"
	"net/http"
	"strings"
)

//go:embed static/*
var staticFiles embed.FS

var roomManager = NewRoomManager()

// Generate a random 6-character room code
func generateRoomCode() string {
	const charset = "ABCDEFGHJKLMNOPQRSTUVWXYZ23456789" // Excluded easily confused chars: I, O, 0, 1
	var code strings.Builder
	for range 6 {
		code.WriteByte(charset[rand.Intn(len(charset))])
	}
	return code.String()
}

func handleCreateRoom(w http.ResponseWriter, r *http.Request) {
	// CORS headers
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Generate a unique code
	var code string
	for {
		code = generateRoomCode()
		if _, exists := roomManager.GetRoom(code); !exists {
			break
		}
	}

	// Create the room
	roomManager.CreateRoom(code)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"code": code,
	})
}

func handleCheckRoom(w http.ResponseWriter, r *http.Request) {
	// CORS headers
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")

	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	code := r.URL.Query().Get("code")
	code = strings.ToUpper(strings.TrimSpace(code))
	if code == "" {
		http.Error(w, "Room code is required", http.StatusBadRequest)
		return
	}

	_, exists := roomManager.GetRoom(code)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"exists": exists,
		"code":   code,
	})
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	roomCode := r.URL.Query().Get("room")
	roomCode = strings.ToUpper(strings.TrimSpace(roomCode))
	nickname := r.URL.Query().Get("nickname")
	nickname = strings.TrimSpace(nickname)

	if roomCode == "" || nickname == "" {
		http.Error(w, "Room code and nickname are required", http.StatusBadRequest)
		return
	}

	room, exists := roomManager.GetRoom(roomCode)
	if !exists {
		http.Error(w, "Room does not exist", http.StatusNotFound)
		return
	}

	ServeWs(room, w, r, nickname)
}

func main() {
	// API Endpoints
	http.HandleFunc("/api/rooms", handleCreateRoom)
	http.HandleFunc("/api/rooms/check", handleCheckRoom)
	http.HandleFunc("/ws", handleWebSocket)

	// Serve Static UI Files
	subFS, err := fs.Sub(staticFiles, "static")
	if err != nil {
		log.Fatalf("failed to create sub filesystem: %v", err)
	}
	http.Handle("/", http.FileServer(http.FS(subFS)))

	// Start Server
	port := ":8080"
	log.Printf("Server starting on port %s", port)
	if err := http.ListenAndServe(port, nil); err != nil {
		log.Fatalf("ListenAndServe error: %v", err)
	}
}
