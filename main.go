package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
	"github.com/patrickmn/go-cache"
	"github.com/ulule/limiter/v3"
	memory "github.com/ulule/limiter/v3/drivers/store/memory"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"

	"github.com/gagliardetto/solana-go"
	"github.com/gagliardetto/solana-go/rpc"
)

// Global vars
var mongoClient *mongo.Client
var apiKeysCollection *mongo.Collection
var solanaClient *rpc.Client
var balanceCache *cache.Cache
var walletLocks sync.Map // map[string]*sync.Mutex

// ---------------- MongoDB ----------------
func initMongo() {
	mongoURI := os.Getenv("DEV_DB_URL")
	dbName := os.Getenv("MONGO_DB")

	clientOptions := options.Client().ApplyURI(mongoURI)
	client, err := mongo.Connect(context.Background(), clientOptions)
	if err != nil {
		log.Fatalf("Mongo connection error: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.Ping(ctx, nil); err != nil {
		log.Fatalf("Mongo ping error: %v", err)
	}

	mongoClient = client
	apiKeysCollection = client.Database(dbName).Collection("api_keys")
	fmt.Println("✅ Connected to MongoDB!")
}

func apiKeyExists(key string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	err := apiKeysCollection.FindOne(ctx, bson.M{
		"key":    key,
		"active": true,
	}).Err()

	return err == nil
}

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

func validateAPIKey(key string) bool {
	return apiKeyExists(key)
}

// ---------------- Middleware ----------------
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

func sendDiscordAlert(message string) {
	webhook := os.Getenv("DISCORD_WEBHOOK_URL")
	if webhook == "" {
		return
	}

	// truncate if > 1900 chars
	if len(message) > 1900 {
		message = message[:1900] + "…"
	}

	payloadMap := map[string]string{"content": message}
	payloadBytes, err := json.Marshal(payloadMap)
	if err != nil {
		log.Println("Failed to marshal Discord payload:", err)
		return
	}

	resp, err := http.Post(webhook, "application/json", strings.NewReader(string(payloadBytes)))
	if err != nil {
		log.Println("Failed to send Discord alert:", err)
		return
	}
	defer resp.Body.Close()

	log.Println("Discord response status:", resp.Status)
}

// Panic recovery middleware (lebih rapi)
func RecoveryWithDiscord() gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			if r := recover(); r != nil {
				stackLines := strings.Split(string(debug.Stack()), "\n")
				if len(stackLines) > 10 {
					stackLines = stackLines[:10] // ambil 10 baris pertama
				}
				msg := fmt.Sprintf("⚠️ PANIC: %v\n```%s```", r, strings.Join(stackLines, "\n"))
				sendDiscordAlert(msg)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Internal Server Error"})
				c.Abort()
			}
		}()
		c.Next()
	}
}

func RateLimitMiddleware() gin.HandlerFunc {
	rate, _ := limiter.NewRateFromFormatted("10-M")
	store := memory.NewStore()
	limiterInstance := limiter.New(store, rate)

	return func(c *gin.Context) {
		ip := c.ClientIP()
		context, _ := limiterInstance.Get(c, ip)
		if context.Reached {
			c.JSON(http.StatusTooManyRequests, gin.H{"error": "Rate limit exceeded"})
			c.Abort()
			return
		}
		c.Next()
	}
}

// ---------------- Solana balance ----------------
func getBalance(ctx context.Context, wallet string) (uint64, error) {
	if val, found := balanceCache.Get(wallet); found {
		return val.(uint64), nil
	}

	muIface, _ := walletLocks.LoadOrStore(wallet, &sync.Mutex{})
	mu := muIface.(*sync.Mutex)

	mu.Lock()
	defer mu.Unlock()

	if val, found := balanceCache.Get(wallet); found {
		return val.(uint64), nil
	}

	pubKey, err := solana.PublicKeyFromBase58(wallet)
	if err != nil {
		return 0, fmt.Errorf("invalid wallet address: %w", err)
	}

	resp, err := solanaClient.GetBalance(ctx, pubKey, rpc.CommitmentFinalized)
	if err != nil {
		return 0, err
	}

	balance := uint64(resp.Value)
	balanceCache.Set(wallet, balance, 10*time.Second)

	return balance, nil
}

// ---------------- Main ----------------
func main() {
	err := godotenv.Load()
	if err != nil {
		log.Println("⚠️ No .env file found, using system env")
	}

	// Mongo
	initMongo()
	defaultKey := os.Getenv("DEFAULT_API_KEY")
	if defaultKey != "" && !apiKeyExists(defaultKey) {
		insertAPIKey(defaultKey)
	}

	// Solana
	rpcURL := os.Getenv("SOLANA_RPC_URL")
	if rpcURL == "" {
		log.Fatal("❌ SOLANA_RPC_URL not set")
	}
	solanaClient = rpc.New(rpcURL)
	balanceCache = cache.New(10*time.Second, 20*time.Second)

	// Gin
	r := gin.New()
	r.Use(gin.Logger())
	r.Use(RecoveryWithDiscord())
	r.Use(RateLimitMiddleware())

	api := r.Group("/api", APIKeyAuthMiddleware())
	{
		api.POST("/get-balance", func(c *gin.Context) {
			var req struct {
				Wallets []string `json:"wallets"`
			}
			if err := c.ShouldBindJSON(&req); err != nil || len(req.Wallets) == 0 {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request body"})
				return
			}

			results := []gin.H{}
			for _, w := range req.Wallets {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				bal, err := getBalance(ctx, w)
				if err != nil {
					results = append(results, gin.H{
						"wallet":  w,
						"error":   err.Error(),
						"balance": 0,
					})
				} else {
					results = append(results, gin.H{
						"wallet":  w,
						"balance": bal,
					})
				}
			}

			c.JSON(http.StatusOK, gin.H{"balances": results})
		})

		api.GET("/panic", func(c *gin.Context) {
			panic("Forced panic for testing Discord webhook!")
		})
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	r.Run(":" + port)
}
