package main

import (
	"log"
	"sync"
	"time"
)

// Message represents the signaling & event structure
type Message struct {
	Type      string      `json:"type"`                // "join", "leave", "offer", "answer", "candidate", "peer-joined"
	Sender    string      `json:"sender"`              // User nickname
	Content   string      `json:"content,omitempty"`   // Optional system descriptions
	Payload   interface{} `json:"payload,omitempty"`   // WebRTC SDP descriptions or ICE candidates
	Timestamp time.Time   `json:"timestamp"`
}

// Room represents a single chatroom
type Room struct {
	Code       string
	Clients    map[*Client]bool
	Broadcast  chan Message
	Register   chan *Client
	Unregister chan *Client
	Mu         sync.Mutex
	CreatedAt  time.Time
}

// NewRoom creates a new chatroom
func NewRoom(code string) *Room {
	return &Room{
		Code:       code,
		Clients:    make(map[*Client]bool),
		Broadcast:  make(chan Message),
		Register:   make(chan *Client),
		Unregister: make(chan *Client),
		CreatedAt:  time.Now(),
	}
}

// Run starts the room's message handling loop
func (r *Room) Run(onEmpty func(string)) {
	log.Printf("Room %s started", r.Code)
	defer log.Printf("Room %s closed", r.Code)

	for {
		select {
		case client := <-r.Register:
			r.Mu.Lock()
			r.Clients[client] = true
			clientCount := len(r.Clients)
			r.Mu.Unlock()
			
			log.Printf("Client %s joined room %s", client.Nickname, r.Code)
			
			// If a new peer joined and we now have 2 clients, notify the other peer to initiate WebRTC
			if clientCount > 1 {
				go func(sender *Client) {
					r.Broadcast <- Message{
						Type:      "peer-joined",
						Sender:    sender.Nickname,
						Content:   sender.Nickname + " entrou. Iniciando conexão WebRTC...",
						Timestamp: time.Now(),
					}
				}(client)
			}

		case client := <-r.Unregister:
			r.Mu.Lock()
			if _, ok := r.Clients[client]; ok {
				delete(r.Clients, client)
				close(client.Send)
				log.Printf("Client %s left room %s", client.Nickname, r.Code)
				
				// Broadcast leave event
				go func(nickname string) {
					r.Broadcast <- Message{
						Type:      "leave",
						Sender:    "System",
						Content:   nickname + " saiu do chat.",
						Timestamp: time.Now(),
					}
				}(client.Nickname)
			}
			isEmpty := len(r.Clients) == 0
			r.Mu.Unlock()

			if isEmpty {
				// Wait for a grace period (e.g. 1 minute) before deleting the room
				go func() {
					time.Sleep(1 * time.Minute)
					r.Mu.Lock()
					stillEmpty := len(r.Clients) == 0
					r.Mu.Unlock()
					if stillEmpty {
						onEmpty(r.Code)
					}
				}()
			}

		case message := <-r.Broadcast:
			r.Mu.Lock()
			for client := range r.Clients {
				// WebRTC signaling is peer-to-peer, so do NOT send back to the sender
				if client.Nickname == message.Sender && message.Type != "leave" {
					continue
				}
				
				select {
				case client.Send <- message:
				default:
					close(client.Send)
					delete(r.Clients, client)
				}
			}
			r.Mu.Unlock()
		}
	}
}

// RoomManager manages all active rooms
type RoomManager struct {
	Rooms map[string]*Room
	Mu    sync.RWMutex
}

// NewRoomManager creates a new RoomManager
func NewRoomManager() *RoomManager {
	return &RoomManager{
		Rooms: make(map[string]*Room),
	}
}

// CreateRoom creates and starts a new room with a unique code
func (rm *RoomManager) CreateRoom(code string) *Room {
	rm.Mu.Lock()
	defer rm.Mu.Unlock()

	room := NewRoom(code)
	rm.Rooms[code] = room
	
	go room.Run(func(emptyCode string) {
		rm.DeleteRoom(emptyCode)
	})

	return room
}

// GetRoom retrieves a room by its code
func (rm *RoomManager) GetRoom(code string) (*Room, bool) {
	rm.Mu.RLock()
	defer rm.Mu.RUnlock()
	room, ok := rm.Rooms[code]
	return room, ok
}

// DeleteRoom deletes a room from the manager
func (rm *RoomManager) DeleteRoom(code string) {
	rm.Mu.Lock()
	defer rm.Mu.Unlock()
	if _, ok := rm.Rooms[code]; ok {
		log.Printf("Deleting empty room %s", code)
		delete(rm.Rooms, code)
	}
}
