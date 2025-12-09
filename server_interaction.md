# Server Interaction Documentation

## Overview
The `legacy_gantt_sync` server provides a real-time synchronization backend for Gantt chart applications using `postgres_crdt`. It supports multi-tenant isolation and uses WebSocket for real-time updates.

## Connection Details
- **Base URL:** `http://<host>:<port>` (Default: `http://localhost:8080`)
- **WebSocket URL:** `ws://<host>:<port>/ws`

## Authentication
The server uses JWT (JSON Web Token) for authentication.

### 1. Register a Tenant
Create a new tenant and an admin user.

**POST** `/auth/register`
```json
{
  "tenantName": "my_team",
  "adminUsername": "admin",
  "adminPassword": "secure_password"
}
```
**Response:** `200 OK`
```json
{
  "tenantId": "my_team",
  "message": "Tenant registered successfully"
}
```

### 2. Login
Obtain an access token.

**POST** `/auth/login`
```json
{
  "username": "admin",
  "password": "secure_password"
}
```
**Response:** `200 OK`
```json
{
  "accessToken": "eyJhbGciOiJIUzI1Ni..."
}
```

### 3. Create Users (Admin only)
Add users to your tenant.

**POST** `/api/users`
**Headers:** `Authorization: Bearer <accessToken>`
```json
{
  "username": "john_doe",
  "password": "user_password"
}
```

## Real-time Synchronization (WebSocket)
Connect to the WebSocket endpoint to receive and send updates.

**URL:** `ws://localhost:8080/ws`
**Headers:** `Authorization: Bearer <accessToken>`

> **Note:** Browser WebSocket API does not support custom headers. You may need to pass the token via query parameter (if supported by server update) or use a library that supports it. Currently, the server expects it in the upgrade request headers.

### Protocol Messages
All messages are JSON objects with a `type` field.

#### Subscribe
Subscribe to a channel (usually the `tenantId`).
```json
{
  "type": "subscribe",
  "channel": "<tenantId>"
}
```
The `tenantId` can be extracted from the JWT payload (`tenant_id` claim) or obtained during registration.

#### Operations
Send data updates (CRDT operations or entity updates).
```json
{
  "type": "UPDATE_TASK",
  "data": {
    "id": "task_123",
    "name": "New Task Name",
    "start_date": 1638200000000,
    "end_date": 1638300000000
    // ... other fields
  },
  "timestamp": 1638200000000,
  "actorId": "user_id"
}
```

### Server Responses
- **On Subscribe:** The server sends all existing tasks for the tenant to the client.
- **On Operation:** The server persists the data and broadcasts the message to all other connected clients in the same channel.

## Example Flow
1. **Register** a new tenant via HTTP.
2. **Login** to get an `accessToken`.
3. **Connect** to WebSocket with `Authorization` header.
4. **Subscribe** to the tenant's channel.
5. **Listen** for incoming `UPDATE_TASK` messages to populate the initial state.
6. **Send** `UPDATE_TASK` messages when the user modifies the Gantt chart.
