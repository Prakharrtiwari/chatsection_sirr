import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:chatsection_sirr/websocketServices.dart';
import 'package:flutter/foundation.dart' show kIsWeb; // For web checks
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:open_file/open_file.dart'; // For opening files
import 'package:path_provider/path_provider.dart'; // For saving files
import 'dart:io' show File, Platform, Directory; // For file operations and platform checks
import 'dart:html' as html; // For web-specific file handling
import 'constants.dart';

Future<Uint8List?> fetchMediaFile(String fileUrl) async {
  final String apiUrl = 'http://localhost/getmedia.php?file_url=$fileUrl';

  try {
    final response = await http.get(Uri.parse(apiUrl));
    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      print('Failed to fetch file: ${response.reasonPhrase}');
      return null;
    }
  } catch (e) {
    print('Error fetching file: $e');
    return null;
  }
}

class ChatScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  final String currentUserCode;

  const ChatScreen({
    Key? key,
    required this.user,
    required this.currentUserCode,
  }) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final WebSocketService _webSocketService = WebSocketService();
  final List<Map<String, dynamic>> _messages = [];
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  bool _isConnected = false;
  StreamSubscription? _webSocketSubscription;

  @override
  void initState() {
    super.initState();
    _initializeWebSocket();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _webSocketService.requestChatHistory(widget.currentUserCode, widget.user['UserCode']);
    });
  }

  Future<Map<String, dynamic>> uploadFile(PlatformFile platformFile) async {
    final uri = Uri.parse('http://localhost/uploadMedia.php');
    var request = http.MultipartRequest('POST', uri);

    final fileName = platformFile.name;
    Uint8List? fileBytes;

    try {
      if (kIsWeb) {
        // On web, platformFile.bytes is available, but platformFile.path is null
        fileBytes = platformFile.bytes;
        if (fileBytes == null) {
          return {'status': 'error', 'message': 'File bytes are not available on web'};
        }
      } else {
        // On non-web platforms, read bytes from the file path if bytes are not available
        if (platformFile.bytes != null) {
          fileBytes = platformFile.bytes;
        } else if (platformFile.path != null) {
          fileBytes = await File(platformFile.path!).readAsBytes();
        } else {
          return {'status': 'error', 'message': 'File path and bytes are not available'};
        }
      }

      // Ensure fileBytes is non-null before proceeding
      if (fileBytes == null) {
        return {'status': 'error', 'message': 'File bytes could not be loaded'};
      }

      // Convert Uint8List to List<int> (though Uint8List is already a List<int>, this ensures type safety)
      final List<int> fileBytesList = fileBytes;

      var mimeType = lookupMimeType(fileName);
      var multipartFile = http.MultipartFile.fromBytes(
        'file',
        fileBytesList, // Pass the non-null List<int>
        filename: fileName,
        contentType: mimeType != null ? MediaType.parse(mimeType) : MediaType('application', 'octet-stream'),
      );

      request.files.add(multipartFile);

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        var result = json.decode(response.body);
        if (result['file_url'] != null) {
          result['file_url'] = result['file_url'].replaceFirst('localhost', '192.168.1.100');
        }
        return result;
      }
      return {'status': 'error', 'message': 'File upload failed: ${response.reasonPhrase}'};
    } catch (e) {
      return {'status': 'error', 'message': 'Error uploading file: $e'};
    }
  }
  String _getMediaMessage(String mediaUrl) {
    final extension = mediaUrl.toLowerCase().split('.').last;
    switch (extension) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return 'Sent a photo';
      case 'pdf':
        return 'Sent a PDF';
      case 'mp3':
      case 'wav':
        return 'Sent an audio';
      case 'mp4':
      case 'mov':
        return 'Sent a video';
      default:
        return 'Sent a file';
    }
  }

  Future<void> _pickAndUploadFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.media,
      );
      if (result == null || result.files.isEmpty) return;

      PlatformFile platformFile = result.files.first;
      final currentUserId = widget.currentUserCode.split('.')[0];
      final chatPartnerId = widget.user['UserCode'].split('.')[0];
      final tempId = 'temp-${DateTime.now().millisecondsSinceEpoch}';

      setState(() {
        _messages.add({
          'id': tempId,
          'sender_id': currentUserId,
          'receiver_id': chatPartnerId,
          'message_text': null,
          'media_url': null,
          'timestamp': DateTime.now().toIso8601String(),
          'is_read': true,
          'is_uploading': true,
        });
        _scrollToBottom();
      });

      var uploadResponse = await uploadFile(platformFile);

      if (uploadResponse['status'] == 'success' && uploadResponse['file_url'] != null) {
        final mediaUrl = uploadResponse['file_url'];
        final mediaMessage = _getMediaMessage(mediaUrl);

        setState(() {
          final messageIndex = _messages.indexWhere((m) => m['id'] == tempId);
          if (messageIndex != -1) {
            _messages[messageIndex] = {
              'id': tempId,
              'sender_id': currentUserId,
              'receiver_id': chatPartnerId,
              'message_text': mediaMessage,
              'media_url': mediaUrl,
              'timestamp': DateTime.now().toIso8601String(),
              'is_read': true,
              'is_uploading': false,
            };
          }
          _scrollToBottom();
        });

        if (_isConnected) {
          _webSocketService.sendMessage(
            senderId: widget.currentUserCode,
            receiverId: widget.user['UserCode'],
            messageText: mediaMessage,
            mediaUrl: mediaUrl,
            groupId: null,
          );
        }
      } else {
        setState(() {
          _messages.removeWhere((m) => m['id'] == tempId);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(uploadResponse['message'] ?? 'File upload failed')),
          );
        }
      }
    } catch (e) {
      print('Error during file upload: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error uploading file')),
        );
      }
    }
  }

  Future<void> _initializeWebSocket() async {
    setState(() => _isConnected = _webSocketService.isConnected());
    if (_isConnected) {
      _setupWebSocketListener();
    } else {
      _webSocketSubscription = _webSocketService.getMessages().listen(
            (message) {
          if (!mounted) return;
          setState(() => _isConnected = _webSocketService.isConnected());
          if (_isConnected) {
            _setupWebSocketListener();
            _webSocketService.requestChatHistory(widget.currentUserCode, widget.user['UserCode']);
          }
        },
        onError: (error) => setState(() => _isConnected = false),
      );
    }
  }

  DateTime _parseTimestamp(String timestamp) {
    try {
      return DateTime.parse(timestamp);
    } catch (e) {
      return DateTime.now();
    }
  }

  void _setupWebSocketListener() {
    _webSocketSubscription?.cancel();
    _webSocketSubscription = _webSocketService.getMessages().listen(
          (message) {
        if (!mounted) return;
        final decodedMessage = jsonDecode(message);

        switch (decodedMessage['type']) {
          case 'chat_history':
            setState(() {
              _messages.clear();
              _messages.addAll((decodedMessage['messages'] as List).map((msg) {
                return {
                  'id': msg['id']?.toString(),
                  'sender_id': msg['sender_id'].toString().split('.')[0],
                  'receiver_id': msg['receiver_id'].toString().split('.')[0],
                  'message_text': msg['message_text'] ?? (msg['media_url'] != null ? _getMediaMessage(msg['media_url']) : null),
                  'media_url': msg['media_url'],
                  'timestamp': msg['timestamp'],
                  'is_read': msg['is_read'] ?? false,
                  'is_uploading': false,
                };
              }).toList());
              _scrollToBottom();
            });
            _markMessagesAsRead();
            break;

          case 'send_message':
            final senderId = decodedMessage['sender_id'].toString().split('.')[0];
            final receiverId = decodedMessage['receiver_id'].toString().split('.')[0];
            final currentUserId = widget.currentUserCode.split('.')[0];
            final chatPartnerId = widget.user['UserCode'].split('.')[0];

            if ((senderId == currentUserId && receiverId == chatPartnerId) ||
                (senderId == chatPartnerId && receiverId == currentUserId)) {
              setState(() {
                final tempIndex = _messages.indexWhere(
                      (m) => m['id'].toString().startsWith('temp-') &&
                      m['sender_id'] == senderId &&
                      m['media_url'] == decodedMessage['media_url'],
                );

                if (tempIndex != -1 && senderId == currentUserId) {
                  _messages[tempIndex] = {
                    'id': decodedMessage['id']?.toString(),
                    'sender_id': senderId,
                    'receiver_id': receiverId,
                    'message_text': decodedMessage['message_text'],
                    'media_url': decodedMessage['media_url'],
                    'timestamp': decodedMessage['timestamp'],
                    'is_read': true,
                    'is_uploading': false,
                  };
                } else {
                  _messages.add({
                    'id': decodedMessage['id']?.toString(),
                    'sender_id': senderId,
                    'receiver_id': receiverId,
                    'message_text': decodedMessage['message_text'] ?? (decodedMessage['media_url'] != null ? _getMediaMessage(decodedMessage['media_url']) : null),
                    'media_url': decodedMessage['media_url'],
                    'timestamp': decodedMessage['timestamp'],
                    'is_read': senderId == currentUserId,
                    'is_uploading': false,
                  });
                }
                _scrollToBottom();
              });

              if (senderId != currentUserId && decodedMessage['id'] != null) {
                _webSocketService.markMessageRead(
                  decodedMessage['id'].toString(),
                  widget.currentUserCode,
                );
              }
            }
            break;

          case 'message_read':
            final messageId = decodedMessage['message_id'].toString();
            final readerId = decodedMessage['reader_id'].toString().split('.')[0];
            final currentUserId = widget.currentUserCode.split('.')[0];

            if (readerId == currentUserId) {
              setState(() {
                final messageIndex = _messages.indexWhere((m) => m['id'] == messageId);
                if (messageIndex != -1) {
                  _messages[messageIndex]['is_read'] = true;
                }
              });
            }
            break;
        }
      },
      onError: (error) => setState(() => _isConnected = false),
      onDone: () => setState(() => _isConnected = false),
    );
  }

  void _markMessagesAsRead() {
    final currentUserId = widget.currentUserCode.split('.')[0];
    final unreadMessages = _messages
        .where((msg) => msg['sender_id'] != currentUserId && msg['id'] != null && !msg['is_read'])
        .toList();

    for (var message in unreadMessages) {
      _webSocketService.markMessageRead(message['id'].toString(), widget.currentUserCode);
    }
  }

  void _sendMessage() {
    if (_messageController.text.trim().isEmpty || !_isConnected) return;

    final messageText = _messageController.text.trim();
    final currentUserId = widget.currentUserCode.split('.')[0];
    final chatPartnerId = widget.user['UserCode'].split('.')[0];
    final tempId = 'temp-${DateTime.now().millisecondsSinceEpoch}';

    setState(() {
      _messages.add({
        'id': tempId,
        'sender_id': currentUserId,
        'receiver_id': chatPartnerId,
        'message_text': messageText,
        'media_url': null,
        'timestamp': DateTime.now().toIso8601String(),
        'is_read': true,
        'is_uploading': false,
      });
      _scrollToBottom();
    });

    _messageController.clear();
    FocusScope.of(context).requestFocus(_messageFocusNode);

    _webSocketService.sendMessage(
      senderId: widget.currentUserCode,
      receiverId: widget.user['UserCode'],
      messageText: messageText,
      mediaUrl: "",
      groupId: null,
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && mounted) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _webSocketSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    super.dispose();
  }

  String _getDateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) return 'Today';
    if (messageDate == yesterday) return 'Yesterday';
    return DateFormat('dd-MM-yyyy').format(date);
  }

  bool _isImage(String url) {
    final lowerCaseUrl = url.toLowerCase();
    return lowerCaseUrl.endsWith('.png') ||
        lowerCaseUrl.endsWith('.jpg') ||
        lowerCaseUrl.endsWith('.jpeg') ||
        lowerCaseUrl.endsWith('.gif');
  }

  bool _isAudio(String url) {
    final lowerCaseUrl = url.toLowerCase();
    return lowerCaseUrl.endsWith('.mp3') || lowerCaseUrl.endsWith('.wav');
  }

  bool _isVideo(String url) {
    final lowerCaseUrl = url.toLowerCase();
    return lowerCaseUrl.endsWith('.mp4') || lowerCaseUrl.endsWith('.mov');
  }

  bool _isPDF(String url) {
    final lowerCaseUrl = url.toLowerCase();
    return lowerCaseUrl.endsWith('.pdf');
  }

  Future<String> _saveFile(String url, Uint8List mediaBytes) async {
    try {
      Directory? directory;
      if (kIsWeb) {
        throw Exception('Saving to a directory is not supported on web');
      }

      try {
        directory = await getDownloadsDirectory();
      } catch (e) {
        // Fallback to application documents directory if getDownloadsDirectory fails
        directory = await getApplicationDocumentsDirectory();
      }

      if (directory == null) {
        throw Exception('Could not access a directory to save the file');
      }

      final fileName = url.split('/').last;
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(mediaBytes);

      return filePath;
    } catch (e) {
      throw Exception('Error saving file: $e');
    }
  }

  Future<void> _downloadMedia(String url) async {
    try {
      final mediaBytes = await fetchMediaFile(url);
      if (mediaBytes != null) {
        if (kIsWeb) {
          // For web, trigger a browser download
          final blob = html.Blob([mediaBytes]);
          final blobUrl = html.Url.createObjectUrlFromBlob(blob);
          final anchor = html.AnchorElement(href: blobUrl)
            ..setAttribute('download', url.split('/').last)
            ..click();
          html.Url.revokeObjectUrl(blobUrl);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File downloaded via browser')),
          );
        } else if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
          final filePath = await _saveFile(url, mediaBytes);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('File downloaded to $filePath')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Downloading is not supported on this platform')),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to download file')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error downloading media: $e')),
      );
    }
  }

  Future<void> _openMedia(String url) async {
    try {
      final mediaBytes = await fetchMediaFile(url);
      if (mediaBytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to fetch media file')),
        );
        return;
      }

      // Determine the file extension and MIME type from the URL
      final fileName = url.split('/').last;
      final extension = fileName.split('.').last.toLowerCase();
      String? mimeType = lookupMimeType(fileName);

      // Fallback MIME type if lookup fails
      mimeType ??= _getMimeTypeFromExtension(extension);

      if (kIsWeb) {
        // For web, create a blob with the correct MIME type and open it in a new tab
        final blob = html.Blob([mediaBytes], mimeType);
        final blobUrl = html.Url.createObjectUrlFromBlob(blob);
        html.window.open(blobUrl, '_blank');
        html.Url.revokeObjectUrl(blobUrl);
      } else if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        // Save the file to a temporary directory with the correct extension
        final tempDir = await getTemporaryDirectory();
        final filePath = '${tempDir.path}/$fileName'; // Ensure the file has the correct extension
        final file = File(filePath);
        await file.writeAsBytes(mediaBytes);

        // Open the file using open_file
        final result = await OpenFile.open(filePath);
        if (result.type != ResultType.done) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Cannot open $url: ${result.message}')),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Opening files is not supported on this platform')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error opening media: $e')),
      );
    }
  }

// Helper method to determine MIME type from file extension
  String _getMimeTypeFromExtension(String extension) {
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'pdf':
        return 'application/pdf';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      default:
        return 'application/octet-stream'; // Fallback for unknown types
    }
  }

  Widget _buildMessageBubble(Map<String, dynamic> message, bool isMe, BuildContext context) {
    final messageDate = _parseTimestamp(message['timestamp']);
    final showReadReceipt = isMe && message['id'] != null && !message['id'].toString().startsWith('temp-');
    final hasMedia = message['media_url'] != null && message['media_url'].toString().isNotEmpty;
    final hasText = message['message_text'] != null && message['message_text'].toString().isNotEmpty;
    final isUploading = message['is_uploading'] == true;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4.0),
      padding: const EdgeInsets.all(12.0),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.75,
      ),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFF1E88E5) : Colors.grey[200],
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(12.0),
          topRight: const Radius.circular(12.0),
          bottomLeft: isMe ? const Radius.circular(12.0) : const Radius.circular(4.0),
          bottomRight: isMe ? const Radius.circular(4.0) : const Radius.circular(12.0),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.2),
            spreadRadius: 1,
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (isUploading)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (hasMedia && !isUploading) ...[
            GestureDetector(
              onTap: () => _openMedia(message['media_url']),
              child: Container(
                margin: const EdgeInsets.only(bottom: 4.0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12.0),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.grey.withOpacity(0.3),
                      spreadRadius: 1,
                      blurRadius: 3,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12.0),
                  child: _isImage(message['media_url'])
                      ? Container(
                    padding: const EdgeInsets.all(8.0),
                    color: Colors.grey[300],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.image, color: Colors.green),
                        const SizedBox(width: 8),
                        const Text('Photo file'),
                      ],
                    ),
                  )
                      : _isAudio(message['media_url'])
                      ? Container(
                    padding: const EdgeInsets.all(8.0),
                    color: Colors.grey[300],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.audiotrack, color: Colors.blue),
                        const SizedBox(width: 8),
                        const Text('Audio file'),
                      ],
                    ),
                  )
                      : _isVideo(message['media_url'])
                      ? Container(
                    padding: const EdgeInsets.all(8.0),
                    color: Colors.grey[300],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam, color: Colors.red),
                        const SizedBox(width: 8),
                        const Text('Video file'),
                      ],
                    ),
                  )
                      : _isPDF(message['media_url'])
                      ? Container(
                    padding: const EdgeInsets.all(8.0),
                    color: Colors.grey[300],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.picture_as_pdf, color: Colors.red),
                        const SizedBox(width: 8),
                        const Text('PDF file'),
                      ],
                    ),
                  )
                      : Container(
                    padding: const EdgeInsets.all(8.0),
                    color: Colors.grey[300],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.insert_drive_file, color: Colors.grey),
                        const SizedBox(width: 8),
                        const Text('File'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Download button for media
            TextButton.icon(
              onPressed: () => _downloadMedia(message['media_url']),
              icon: Icon(
                Icons.download,
                color: isMe ? Colors.white : Colors.blue,
                size: 20,
              ),
              label: Text(
                'Download',
                style: TextStyle(
                  color: isMe ? Colors.white : Colors.blue,
                  fontSize: 14,
                ),
              ),
            ),
          ],
          if (hasText)
            Padding(
              padding: hasMedia ? const EdgeInsets.only(top: 8.0) : EdgeInsets.zero,
              child: Text(
                message['message_text'],
                style: TextStyle(
                  color: isMe ? Colors.white : Colors.black87,
                  fontSize: 16,
                ),
              ),
            ),
          const SizedBox(height: 4.0),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DateFormat('HH:mm').format(messageDate),
                style: TextStyle(
                  fontSize: 12,
                  color: isMe ? Colors.white70 : Colors.grey[600],
                ),
              ),
              if (showReadReceipt) ...[
                const SizedBox(width: 4.0),
                Icon(
                  message['is_read'] == true ? Icons.done_all : Icons.done,
                  size: 14,
                  color: message['is_read'] == true ? Colors.white : Colors.white70,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = widget.currentUserCode.split('.')[0];

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: Colors.white.withOpacity(0.2),
              child: widget.user['UserPhoto'] != null && widget.user['UserPhoto'].isNotEmpty
                  ? ClipOval(
                child: Image.memory(
                  base64Decode(widget.user['UserPhoto']),
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                ),
              )
                  : Text(
                widget.user['UserName']?.substring(0, 1).toUpperCase() ?? 'U',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.user['UserName'] ?? 'Unknown User',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    _isConnected ? 'Online' : 'Offline',
                    style: TextStyle(
                      fontSize: 12,
                      color: _isConnected ? Colors.greenAccent[100] : Colors.grey[300],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1E88E5), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        elevation: 8,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: Icon(
              _isConnected ? Icons.wifi : Icons.wifi_off,
              color: _isConnected ? Colors.greenAccent : Colors.redAccent,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
              child: Text(
                'No messages yet',
                style: TextStyle(color: Colors.grey[600], fontSize: 16),
              ),
            )
                : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16.0),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                final isMe = message['sender_id'] == currentUserId;
                final currentDate = _parseTimestamp(message['timestamp']);
                final previousMessage = index > 0 ? _messages[index - 1] : null;
                final previousDate =
                previousMessage != null ? _parseTimestamp(previousMessage['timestamp']) : null;

                final showDateDivider = previousDate == null ||
                    currentDate.day != previousDate.day ||
                    currentDate.month != previousDate.month ||
                    currentDate.year != previousDate.year;

                return Column(
                  children: [
                    if (showDateDivider)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                          decoration: BoxDecoration(
                            color: Colors.grey[300],
                            borderRadius: BorderRadius.circular(12.0),
                          ),
                          child: Text(
                            _getDateLabel(currentDate),
                            style: TextStyle(
                              color: Colors.grey[700],
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: _buildMessageBubble(message, isMe, context),
                    ),
                  ],
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.2),
                  spreadRadius: 1,
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    focusNode: _messageFocusNode,
                    decoration: InputDecoration(
                      hintText: _isConnected ? 'Type a message...' : 'Disconnected',
                      hintStyle: TextStyle(color: Colors.grey[500]),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30.0),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Colors.grey[200],
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
                      suffixIcon: _isConnected
                          ? IconButton(
                        icon: const Icon(Icons.attach_file),
                        onPressed: _pickAndUploadFile,
                      )
                          : const Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
                    ),
                    enabled: _isConnected,
                    onSubmitted: (_) => _sendMessage(),
                    minLines: 1,
                    maxLines: 5,
                  ),
                ),
                const SizedBox(width: 10.0),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: _isConnected
                        ? const LinearGradient(
                      colors: [Color(0xFF1E88E5), Color(0xFF42A5F5)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                        : const LinearGradient(colors: [Colors.grey, Colors.grey]),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: _isConnected ? _sendMessage : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}