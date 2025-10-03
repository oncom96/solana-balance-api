package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime/debug"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// Global vars
var mongoClient *mongo.Client
var apiKeysCollection *mongo.Collection

// Init MongoDB
func initMongo() {
	mongoURI := os.Getenv("DEV_DB_URL")
	dbName := os.Getenv("MONGO_DB")

	clientOptions := options.Client().ApplyURI(mongoURI)
	client, err := mongo.Connect(context.Background(), clientOptions)
	if err != nil {
		log.Fatalf("Mongo connection error: %v", err)
	}

	// Ping
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.Ping(ctx, nil); err != nil {
		log.Fatalf("Mongo ping error: %v", err)
	}

	mongoClient = client
	apiKeysCollection = client.Database(dbName).Collection("api_keys")
	fmt.Println("✅ Connected to MongoDB!")
}

// Check if API key exists
func apiKeyExists(key string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	err := apiKeysCollection.FindOne(ctx, bson.M{
		"key":    key,
		"active": true,
	}).Err()

	return err == nil
}

// Insert API key
func insertAPIKey(key string) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	_, err := apiKeysCollection.InsertOne(ctx, bson.M{
		"key":       key,
		"active":    true,
		"createdAt": time.Now(),
	})
	if err != nil {
		log.Fatalf("Failed to insert API key: %v", err)
	}
	fmt.Println("✅ Default API key inserted:", key)
}

// Validate API key
func validateAPIKey(key string) bool {
	return apiKeyExists(key)
}

// Middleware API key
func APIKeyAuthMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		apiKey := c.GetHeader("x-api-key")
		if apiKey == "" || !validateAPIKey(apiKey) {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "Invalid or missing API key"})
			c.Abort()
			return
		}
		c.Next()
	}
}

// Send alert to Discord
func sendDiscordAlert(message string) {
	webhook := os.Getenv("DISCORD_WEBHOOK_URL")
	if webhook == "" {
		return
	}

	payload := strings.NewReader(fmt.Sprintf(`{"content": "%s"}`, message))
	resp, err := http.Post(webhook, "application/json", payload)
	if err != nil {
		log.Println("Failed to send Discord alert:", err)
		return
	}
	defer resp.Body.Close()
}

// Panic recovery middleware
func RecoveryWithDiscord() gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			if r := recover(); r != nil {
				trace := string(debug.Stack())
				msg := fmt.Sprintf("⚠️ PANIC: %v\n```%s```", r, trace)
				sendDiscordAlert(msg)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Internal Server Error"})
				c.Abort()
			}
		}()
		c.Next()
	}
}

func main() {
	// Load .env
	err := godotenv.Load()
	if err != nil {
		log.Println("⚠️ No .env file found, using system env")
	}

	// Init Mongo
	initMongo()

	// Insert default API key if not exist
	defaultKey := os.Getenv("DEFAULT_API_KEY")
	if defaultKey != "" && !apiKeyExists(defaultKey) {
		insertAPIKey(defaultKey)
	}

	// Gin setup
	r := gin.New()
	r.Use(gin.Logger())
	r.Use(RecoveryWithDiscord())

	// Protected routes
	api := r.Group("/api", APIKeyAuthMiddleware())
	{
		api.POST("/get-balance", func(c *gin.Context) {
			// sementara dummy response
			c.JSON(http.StatusOK, gin.H{"message": "Balance API - Auth OK"})
		})

		// Endpoint buat force panic
		api.GET("/panic", func(c *gin.Context) {
			panic("Forced panic for testing Discord webhook!")
		})
	}

	// Run server
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	r.Run(":" + port)
}
