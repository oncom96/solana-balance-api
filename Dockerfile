# Stage build
FROM golang:1.24 AS builder
WORKDIR /app

# Copy go.mod & go.sum dulu biar cache lebih efisien
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build binary (static build)
RUN CGO_ENABLED=0 GOOS=linux go build -o solana-api main.go

# Stage runtime ringan
FROM gcr.io/distroless/base-debian12
WORKDIR /app

# copy binary
COPY --from=builder /app/solana-api .

# kalau butuh .env, bisa di-copy (opsional, biasanya lebih baik pakai env vars)
# COPY .env .env

EXPOSE 8080

# distroless butuh path absolute ke binary
ENTRYPOINT ["/app/solana-api"]
