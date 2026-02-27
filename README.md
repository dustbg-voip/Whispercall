Whisper Call iOS App

A native iOS companion app for the WebRTC Mini Chat WordPress Widget. This app allows site administrators to respond to website visitors directly from their iPhone, with support for text, file sharing, and audio/video calls.

<img src="https://github.com/dustbg-voip/Whispercall/blob/main/WhisperCall/Assets.xcassets/Screenshots/Image.imageset/1200.jpg?raw=true" width="300"/>
Features
Real-time Chat: Instant messaging with website visitors.

Audio & Video Calls: Full WebRTC support for high-quality calls.

File Sharing: Send and receive documents, images, and more.

Session Management: Archive important conversations and manage active chats.

Custom Server: Connect to your own self-hosted WebSocket server.

Optimized for Admin Use: Clean interface designed for managing multiple visitor conversations.

How It Works with the WordPress Widget
This app is designed to work seamlessly with the WebRTC Mini Chat WordPress Plugin. Your WordPress site acts as the server, and this app allows you, the admin, to respond to visitors from your iOS device.

Server-Side Requirement
You must have the WebRTC Mini Chat Widget installed and configured on your WordPress site. The plugin handles the WebSocket server connection and the front-end chat widget for your visitors.

Get the WordPress Plugin Here

App Setup & Configuration
First Launch: Connecting to Your Server
Install & Open: Install the Whisper Call app on your iPhone and open it.

Enter Server URL: On the initial setup screen, you will be prompted to enter your server's WebSocket URL.

This is the same URL you configured in your WordPress admin panel (Settings → WebRTC Chat).

Examples:

wss://your-domain.com/ws (for production with SSL)

ws://192.168.1.100:8080 (for local network development)

Connect: Tap "Connect to Server". The app will save this address and attempt to establish a connection.

Changing the Server Later
In the main chat list, tap the "Change Server" button in the top-right corner to enter a new address and reconnect.

Usage
Once connected, the app will display a list of active visitor chats from your website.

Chat List: Shows the visitor's name/ID, the last message, and connection status.

Chat View: Tap a chat to open it. Send text messages, attach files, or start an audio/video call.

Calling: Use the phone button in the chat header to initiate a call. The call interface is a native iOS overlay.

Development & Custom Server
This app is built to be server-agnostic. It does not rely on any third-party cloud service. As long as your backend implements the correct WebSocket protocol (as defined by the WordPress plugin), the app will work.

Protocol: The app communicates using JSON messages over a WebSocket connection.

File Uploads: Files are sent to an upload.php endpoint located at the same base domain as your WebSocket server (e.g., https://your-domain.com/upload.php).


Contact & Demo
For questions about setting up your own server or to request demo access, please contact:

Jordan Babov – jbabov@me.com
