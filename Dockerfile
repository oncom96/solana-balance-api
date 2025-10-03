# Stage build
FROM golang:1.24 AS builder
WORKDIR /app

# Copy go.mod & go.sum dulu biar cache lebih efisien
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build binary
RUN go build -o solana-api main.go

# Stage runtime ringan
FROM gcr.io/distroless/base-debian12
WORKDIR /app
COPY --from=builder /app/solana-api .

EXPOSE 8080
CMD ["./solana-api"]
