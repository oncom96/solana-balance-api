# Stage build
FROM golang:1.24 AS builder
WORKDIR /app

# Copy go.mod & go.sum
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build binary (static build)
RUN CGO_ENABLED=0 GOOS=linux go build -o solana-api main.go

# Stage runtime light
FROM gcr.io/distroless/base-debian12
WORKDIR /app

# copy binary
COPY --from=builder /app/solana-api .


EXPOSE 8080


ENTRYPOINT ["/app/solana-api"]
