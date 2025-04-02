import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketService {
  static final WebSocketService _instance = WebSocketService._internal();
  factory WebSocketService() => _instance;
  WebSocketService._internal();

  WebSocketChannel? _channel;
  String? _currentUserId;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  static const Duration _baseReconnectDelay = Duration(seconds: 2);
  final StreamController<dynamic> _messageController = StreamController.broadcast();

  Future<bool> connect(String serverUrl, String userId) async {
    disconnect(); // Close any existing connection
    _currentUserId = userId;

    try {
      print('Attempting to connect to $serverUrl with userId: $userId');
      _channel = WebSocketChannel.connect(Uri.parse('$serverUrl?userId=$userId'));
      await _channel!.ready;
      print('WebSocket connection established');

      _channel!.sink.add(jsonEncode({
        'type': 'register_user',
        'user_id': userId,
      }));

      _startHeartbeat();
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      return true;
    } catch (e) {
      print('WebSocket connection failed: $e');
      _channel?.sink.close();
      _channel = null;
      _scheduleReconnect();
      return false;
    }
  }
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (isConnected()) {
        try {
          _channel!.sink.add(jsonEncode({'type': 'ping'}));
          print('Sent ping to server');
        } catch (e) {
          print('Failed to send ping: $e');
          timer.cancel();
          _scheduleReconnect();
        }
      } else {
        print('Heartbeat detected disconnection');
        timer.cancel();
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts || _currentUserId == null) {
      print('Max reconnect attempts ($_maxReconnectAttempts) reached or no user ID. Giving up.');
      return;
    }

    _reconnectTimer?.cancel();
    final delay = _baseReconnectDelay * (1 << _reconnectAttempts);
    print('Scheduling reconnect attempt ${_reconnectAttempts + 1} in ${delay.inSeconds} seconds');

    _reconnectTimer = Timer(delay, () async {
      _reconnectAttempts++;
      await connect('ws://192.168.254.51:8181/', _currentUserId!);
      if (isConnected()) {
        listenToMessages(); // Re-establish the listener after reconnect
      }
    });
  }

  void sendMessage({
    required String senderId,
    required String receiverId,
    String? groupId,
    required String messageText,
    String? mediaUrl,
  }) {
    if (!isConnected()) {
      print('WebSocket not connected. Attempting to reconnect.');
      _scheduleReconnect();
      return;
    }

    int senderIdInt;
    int? receiverIdInt;
    try {
      senderIdInt = int.parse(senderId.split('.')[0]);
      receiverIdInt = receiverId.isNotEmpty ? int.parse(receiverId.split('.')[0]) : null;
    } catch (e) {
      print('Failed to parse IDs: senderId=$senderId, receiverId=$receiverId, error=$e');
      return;
    }

    final message = {
      'type': 'send_message',
      'sender_id': senderIdInt,
      'receiver_id': receiverIdInt,
      'group_id': groupId,
      'message_text': messageText,
      'media_url': mediaUrl,
      'timestamp': DateTime.now().toIso8601String(),
    };

    try {
      print('Sending message: $message');
      _channel!.sink.add(jsonEncode(message));
    } catch (e) {
      print('Failed to send message: $e');
      _scheduleReconnect();
    }
  }

  void requestChatHistory(String userId, String chatPartnerId) {
    if (isConnected()) {
      try {
        final message = {
          'type': 'get_chat_history',
          'user_id': int.parse(userId.split('.')[0]),
          'chat_partner_id': int.parse(chatPartnerId.split('.')[0]),
        };
        _channel!.sink.add(jsonEncode(message));
        print('Requested chat history: $message');
      } catch (e) {
        print('Failed to request chat history: $e');
      }
    } else {
      print('Cannot request chat history: WebSocket not connected');
      _scheduleReconnect();
    }
  }

  void requestGroupChatHistory(String groupId) {
    if (isConnected()) {
      try {
        final message = {
          'type': 'get_group_chat_history',
          'group_id': groupId,
        };
        _channel!.sink.add(jsonEncode(message));
        print('Requested group chat history: $message');
      } catch (e) {
        print('Failed to request group chat history: $e');
      }
    } else {
      print('Cannot request group chat history: WebSocket not connected');
      _scheduleReconnect();
    }
  }

  void requestChatList(String userId) {
    if (isConnected()) {
      _channel!.sink.add(jsonEncode({'type': 'get_chat_list', 'user_id': int.parse(userId.split('.')[0])}));
    }
  }

  void requestGroupList(String userId) {
    if (isConnected()) {
      _channel!.sink.add(jsonEncode({'type': 'get_group_list', 'user_id': int.parse(userId.split('.')[0])}));
    }
  }

  void markAllMessagesReadInChat(String partnerId, String userId) {
    if (isConnected()) {
      try {
        final message = {
          'type': 'mark_all_messages_read',
          'partner_id': partnerId,
          'user_id': int.parse(userId.split('.')[0]),
        };
        print('Sending WebSocket message: ${jsonEncode(message)}');
        _channel!.sink.add(jsonEncode(message));
        print('Requesting to mark all messages as read for chat with: $partnerId');
      } catch (e) {
        print('Failed to mark all messages as read: $e');
      }
    } else {
      print('Cannot mark messages as read: WebSocket not connected');
      _scheduleReconnect();
    }
  }

  void markAllMessagesReadInGroup(String groupId, String userId) {
    if (isConnected()) {
      try {
        final message = {
          'type': 'mark_all_group_messages_read',
          'group_id': groupId,
          'user_id': int.parse(userId.split('.')[0]),
        };
        print('Sending WebSocket message: ${jsonEncode(message)}');
        _channel!.sink.add(jsonEncode(message));
        print('Requesting to mark all messages as read for group: $groupId');
      } catch (e) {
        print('Failed to mark all group messages as read: $e');
      }
    } else {
      print('Cannot mark group messages as read: WebSocket not connected');
      _scheduleReconnect();
    }
  }

  void markMessageRead(String? messageId, String userId) {
    if (messageId == null) {
      print('Cannot mark message as read: message_id is null');
      return;
    }
    if (isConnected()) {
      try {
        final message = {
          'type': 'mark_message_read',
          'message_id': messageId,
          'user_id': int.parse(userId.split('.')[0]),
        };
        print('Sending WebSocket message: ${jsonEncode(message)}');
        _channel!.sink.add(jsonEncode(message));
        print('Marked message as read: $message');
      } catch (e) {
        print('Failed to mark message as read: $e');
      }
    } else {
      print('Cannot mark message as read: WebSocket not connected');
      _scheduleReconnect();
    }
  }
  Stream<dynamic> getMessages() => _messageController.stream;

  void listenToMessages() {
    _channel?.stream.listen(
          (message) {
        print('WebSocketService received raw message: $message');
        if (!_messageController.isClosed) {
          _messageController.add(message);
        } else {
          print('Cannot add message to stream: StreamController is closed');
        }
      },
      onError: (error) {
        print('WebSocket error: $error');
        if (!_messageController.isClosed) {
          _messageController.addError(error);
        }
        _scheduleReconnect();
      },
      onDone: () {
        print('WebSocket closed with code: ${_channel?.closeCode}');
        _scheduleReconnect();
      },
    );
  }

  bool isConnected() {
    final connected = _channel != null && _channel!.sink != null;
    print('Connection status check: $connected');
    return connected;
  }

  void disconnect() {
    print('Disconnecting WebSocket');
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _reconnectAttempts = 0;
    _currentUserId = null;
    // Do NOT close the _messageController here
    // _messageController.close(); // Removed to prevent "Bad state" error
  }
}