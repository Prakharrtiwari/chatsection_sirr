import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:chatsection_sirr/websocketServices.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'chatScreen.dart';
import 'constants.dart';
import 'createGroupPage.dart';
import 'groupchatPage.dart';
import 'main.dart';
import 'newChats.dart';

class ChatPage extends StatefulWidget {
  final String userCode;

  const ChatPage({super.key, required this.userCode});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  List<ChatItem> chats = [];
  List<GroupItem> groups = [];
  List<ChatItem> filteredChats = [];
  List<GroupItem> filteredGroups = [];
  bool isSearching = false;
  final WebSocketService _webSocketService = WebSocketService();
  bool _isConnected = false;
  bool _isOpeningChat = false;
  Timer? _refreshTimer;
  final ScrollController _chatScrollController = ScrollController();
  final ScrollController _groupScrollController = ScrollController();
  Map<String, bool> _newMessageHighlight = {};
  Map<String, DateTime> _lastReadTimestamps = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initializeWebSocket();
    _startPeriodicRefresh();

    _searchController.addListener(_onSearchChanged);
    _tabController.addListener(() => setState(() {}));
    _fetchAndStoreUserData();
  }

  Future<void> _initializeWebSocket() async {
    try {
      _isConnected = await _webSocketService.connect('ws://192.168.254.51:8181/', widget.userCode);
      setState(() {});

      if (_isConnected) {
        _webSocketService.listenToMessages();
        _setupWebSocketListener();
        _fetchInitialData();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to connect to chat server')),
          );
        }
      }
    } catch (e, stackTrace) {
      // Print error with highlighting and stack trace
      print('\x1B[31m[ERROR] \x1B[0m$e');  // Red highlighting for error
      print('\x1B[33m[STACK TRACE] \x1B[0m$stackTrace');  // Yellow for stack trace
    }
  }



  void _openChatOrGroup(dynamic item, bool isGroup) async {
    setState(() {
      _isOpeningChat = true;
      // Immediately update the UI to show no unread messages
      if (isGroup) {
        final groupIndex = groups.indexWhere((g) => g.groupId == item.groupId);
        if (groupIndex != -1) {
          groups[groupIndex].unreadCount = 0;
          _newMessageHighlight[item.groupId] = false;
          _lastReadTimestamps[item.groupId] = DateTime.now();
        }
      } else {
        final chatIndex = chats.indexWhere((c) => c.userCode == item.userCode);
        if (chatIndex != -1) {
          chats[chatIndex].unreadCount = 0;
          _newMessageHighlight[item.userCode] = false;
          _lastReadTimestamps[item.userCode] = DateTime.now();
        }
      }
    });

    if (isGroup) {
      final groupId = (item as GroupItem).groupId;
      // Request to mark all as read AFTER UI update
      _webSocketService.markAllMessagesReadInGroup(groupId, widget.userCode);
      _webSocketService.requestGroupChatHistory(groupId);

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => GroupChatScreen(
            groupId: groupId,
            groupName: item.displayName,
            groupMembers: [],
          ),
        ),
      );
    } else {
      final chatPartnerId = (item as ChatItem).userCode;
      // Request to mark all as read AFTER UI update
      _webSocketService.markAllMessagesReadInChat(chatPartnerId, widget.userCode);
      _webSocketService.requestChatHistory(widget.userCode, chatPartnerId);

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            user: {
              'UserCode': chatPartnerId,
              'UserName': item.displayName,
              'UserPhoto': item.photoUrl,
            },
            currentUserCode: AppConstants.userCode,
          ),
        ),
      );
    }

    setState(() => _isOpeningChat = false);
    await Future.delayed(const Duration(milliseconds: 500));
    _fetchInitialData(); // This will sync with server and correct any discrepancies
  }

  void _fetchInitialData() {
    if (_isConnected) {
      _webSocketService.requestChatList(widget.userCode);
      _webSocketService.requestGroupList(widget.userCode);
    }
  }

  void _startPeriodicRefresh() {
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_isConnected && mounted && !_isOpeningChat) {
        _fetchInitialData();
      }
    });
  }

  void _setupWebSocketListener() {
    _webSocketService.getMessages().listen(
          (message) {
        if (!mounted) return;
        print('ChatPage received message: $message');
        try {
          final decodedMessage = jsonDecode(message);
          setState(() {
            switch (decodedMessage['type']) {
              case 'chat_list':
                _updateChatList(decodedMessage['chats']);
                break;
              case 'group_list':
                _updateGroupList(decodedMessage['groups']);
                break;
              case 'send_message':
                _handleIncomingMessage(decodedMessage);
                break;
              case 'pong':
                break;
              case 'error':
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Server error: ${decodedMessage['message']}')),
                );
                break;
              default:
                print('ChatPage: Unhandled message type: ${decodedMessage['type']}');
            }
          });
        } catch (e, stackTrace) {
          print('ChatPage: Error processing WebSocket message: $e');
          print('Stack trace: $stackTrace');
        }
      },
      onError: (error) {
        print('ChatPage: WebSocket error: $error');
        setState(() => _isConnected = false);
      },
      onDone: () {
        print('ChatPage: WebSocket closed');
        setState(() => _isConnected = false);
      },
    );
  }

  DateTime _parseTimestamp(String timestamp) {
    try {
      return DateTime.parse(timestamp);
    } catch (e) {
      print('Error parsing timestamp "$timestamp": $e');
      return DateTime.now();
    }
  }

  void _updateChatList(List<dynamic> newChats) {
    chats = newChats.map((chat) {
      final chatId = chat['chat_partner_id'].toString();
      final lastRead = _lastReadTimestamps[chatId];
      final serverTimestamp = chat['last_timestamp'] != null
          ? _parseTimestamp(chat['last_timestamp'])
          : DateTime.now();

      final unreadCount = (lastRead != null && serverTimestamp.isBefore(lastRead))
          ? 0
          : (chat['unread_count'] is String
          ? int.parse(chat['unread_count'])
          : (chat['unread_count'] ?? 0));

      return ChatItem(
        userCode: chatId,
        displayName: chat['chat_with_name'] ?? chatId,
        photoUrl: chat['chat_with_photo'],
        lastMessage: chat['last_message'] ?? '',
        timestamp: serverTimestamp,
        unreadCount: unreadCount,
        isPinned: chats.firstWhere(
              (c) => c.userCode == chatId,
          orElse: () => ChatItem(
            userCode: chatId,
            displayName: chat['chat_with_name'] ?? chatId,
            photoUrl: chat['chat_with_photo'],
            lastMessage: chat['last_message'] ?? '',
            timestamp: serverTimestamp,
            unreadCount: unreadCount,
            isPinned: false,
          ),
        ).isPinned,
      );
    }).toList();

    chats.sort((a, b) => a.isPinned == b.isPinned
        ? b.timestamp.compareTo(a.timestamp)
        : (a.isPinned ? -1 : 1));
    _applySearchFilter();
    if (chats.isNotEmpty) {
      _chatScrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _updateGroupList(List<dynamic> newGroups) {
    groups = newGroups.map((group) {
      final groupId = group['group_id'].toString();
      final lastRead = _lastReadTimestamps[groupId];
      final serverTimestamp = group['last_timestamp'] != null
          ? _parseTimestamp(group['last_timestamp'])
          : DateTime.now();

      final unreadCount = (lastRead != null && serverTimestamp.isBefore(lastRead))
          ? 0
          : (group['unread_count'] is String
          ? int.parse(group['unread_count'])
          : (group['unread_count'] ?? 0));

      return GroupItem(
        groupId: groupId,
        displayName: group['group_name'] ?? groupId,
        lastMessage: group['last_message'] ?? '',
        timestamp: serverTimestamp,
        unreadCount: unreadCount,
        isPinned: groups.firstWhere(
              (g) => g.groupId == groupId,
          orElse: () => GroupItem(
            groupId: groupId,
            displayName: group['group_name'] ?? groupId,
            lastMessage: group['last_message'] ?? '',
            timestamp: serverTimestamp,
            unreadCount: unreadCount,
            isPinned: false,
          ),
        ).isPinned,
      );
    }).toList();

    groups.sort((a, b) => a.isPinned == b.isPinned
        ? b.timestamp.compareTo(a.timestamp)
        : (a.isPinned ? -1 : 1));
    _applySearchFilter();
    if (groups.isNotEmpty) {
      _groupScrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _handleIncomingMessage(Map<String, dynamic> decodedMessage) {
    final timestamp = _parseTimestamp(decodedMessage['timestamp']);
    final isIncoming = decodedMessage['sender_id'].toString() != widget.userCode;

    if (decodedMessage['group_id'] == null) {
      final chatPartnerId = decodedMessage['sender_id'].toString() == widget.userCode
          ? decodedMessage['receiver_id'].toString()
          : decodedMessage['sender_id'].toString();

      final existingChatIndex = chats.indexWhere((chat) => chat.userCode == chatPartnerId);

      if (existingChatIndex != -1) {
        chats[existingChatIndex] = ChatItem(
          userCode: chats[existingChatIndex].userCode,
          displayName: chats[existingChatIndex].displayName,
          photoUrl: chats[existingChatIndex].photoUrl,
          lastMessage: decodedMessage['message_text'] ?? '',
          timestamp: timestamp,
          unreadCount: isIncoming
              ? chats[existingChatIndex].unreadCount + 1
              : chats[existingChatIndex].unreadCount,
          isPinned: chats[existingChatIndex].isPinned,
        );
        if (isIncoming) {
          _newMessageHighlight[chatPartnerId] = true;
        }
      } else {
        chats.add(ChatItem(
          userCode: chatPartnerId,
          displayName: chatPartnerId,
          photoUrl: null,
          lastMessage: decodedMessage['message_text'] ?? '',
          timestamp: timestamp,
          unreadCount: isIncoming ? 1 : 0,
          isPinned: false,
        ));
        if (isIncoming) {
          _newMessageHighlight[chatPartnerId] = true;
        }
      }
      chats.sort((a, b) => a.isPinned == b.isPinned
          ? b.timestamp.compareTo(a.timestamp)
          : (a.isPinned ? -1 : 1));
      _applySearchFilter();
      _chatScrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      final groupId = decodedMessage['group_id'].toString();
      final existingGroupIndex = groups.indexWhere((group) => group.groupId == groupId);

      if (existingGroupIndex != -1) {
        groups[existingGroupIndex] = GroupItem(
          groupId: groupId,
          displayName: groups[existingGroupIndex].displayName,
          lastMessage: decodedMessage['message_text'] ?? '',
          timestamp: timestamp,
          unreadCount: isIncoming
              ? groups[existingGroupIndex].unreadCount + 1
              : groups[existingGroupIndex].unreadCount,
          isPinned: groups[existingGroupIndex].isPinned,
        );
        if (isIncoming) {
          _newMessageHighlight[groupId] = true;
        }
      } else {
        groups.add(GroupItem(
          groupId: groupId,
          displayName: groupId,
          lastMessage: decodedMessage['message_text'] ?? '',
          timestamp: timestamp,
          unreadCount: isIncoming ? 1 : 0,
          isPinned: false,
        ));
        if (isIncoming) {
          _newMessageHighlight[groupId] = true;
        }
      }
      groups.sort((a, b) => a.isPinned == b.isPinned
          ? b.timestamp.compareTo(a.timestamp)
          : (a.isPinned ? -1 : 1));
      _applySearchFilter();
      _groupScrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _markMessagesAsRead(List<String> messageIds, String chatId, bool isGroup) {
    // Update UI immediately
    setState(() {
      if (isGroup) {
        final groupIndex = groups.indexWhere((g) => g.groupId == chatId);
        if (groupIndex != -1) {
          groups[groupIndex].unreadCount = 0;
          _newMessageHighlight[chatId] = false;
          _lastReadTimestamps[chatId] = DateTime.now();
        }
      } else {
        final chatIndex = chats.indexWhere((c) => c.userCode == chatId);
        if (chatIndex != -1) {
          chats[chatIndex].unreadCount = 0;
          _newMessageHighlight[chatId] = false;
          _lastReadTimestamps[chatId] = DateTime.now();
        }
      }
    });

    // Then send to server
    final currentUserId = widget.userCode.split('.')[0];
    for (var messageId in messageIds) {
      final cleanMessageId = messageId.split('.')[0];
      _webSocketService.markMessageRead(cleanMessageId, currentUserId);
    }
  }

  void _applySearchFilter() {
    setState(() {
      if (_searchController.text.isEmpty) {
        filteredChats = List.from(chats);
        filteredGroups = List.from(groups);
        isSearching = false;
      } else {
        isSearching = true;
        filteredChats = chats
            .where((chat) =>
        chat.displayName.toLowerCase().contains(_searchController.text.toLowerCase()) ||
            chat.lastMessage.toLowerCase().contains(_searchController.text.toLowerCase()))
            .toList();
        filteredGroups = groups
            .where((group) =>
        group.displayName.toLowerCase().contains(_searchController.text.toLowerCase()) ||
            group.lastMessage.toLowerCase().contains(_searchController.text.toLowerCase()))
            .toList();
      }
    });
  }

  void _onSearchChanged() {
    _applySearchFilter();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _tabController.dispose();
    _searchController.dispose();
    _webSocketService.disconnect();
    _chatScrollController.dispose();
    _groupScrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchAndStoreUserData() async {
    final userData = await getUserByUserCode(widget.userCode,context);
    if (userData != null) {
      AppConstants.userCode = userData['UserCode']?.toString() ?? '';
      AppConstants.userName = userData['UserName'] ?? '';
      AppConstants.userDesignationCode = userData['UserDesignationCode']?.toString() ?? '';
      AppConstants.userPhoto = userData['UserPhoto'] ?? '';
      AppConstants.companyEmailID = userData['CompanyEmailID'] ?? '';
      AppConstants.personalMobile = userData['PersonalMobile'] ?? '';

      // if (mounted) {
      //   ScaffoldMessenger.of(context).showSnackBar(
      //     SnackBar(content: Text('Logged in as ${AppConstants.userName}')),
      //   );
      // }
    }
  }

  String _getDisplayName(String fullName) {
    if (fullName.isEmpty) return 'Messages'; // Fallback if name not loaded

    // Split name into parts and take first name only if name is long
    final nameParts = fullName.split(' ');
    if (nameParts.length > 1 && fullName.length > 12) {
      return nameParts[0];
    }
    return fullName;
  }

  Future<Map<String, dynamic>?> getUserByUserCode(String userCode, BuildContext context) async {
    final Uri url = Uri.parse("http://61.95.220.82/mobileAPI/Prakhar/get_your_own_Data.php?UserCode=$userCode");
    try {
      final response = await http.get(url, headers: {"Content-Type": "application/json"});

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data["data"] != null) {
          return data["data"];
        } else {
          // Show error popup and navigate back
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('No user found with this code', style: TextStyle(color: Colors.white)),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 3),
              ),
            );
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => const LoginPage()),
                  (Route<dynamic> route) => false,
            );
          }
          return null;
        }
      } else {
        // Show error popup for non-200 status code
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error: ${response.statusCode} - User not found', style: const TextStyle(color: Colors.white)),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const LoginPage()),
                (Route<dynamic> route) => false,
          );
        }
        return null;
      }
    } catch (e) {
      print("Error fetching user: $e");
      // Show error popup for exceptions
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection error: ${e.toString()}', style: const TextStyle(color: Colors.white)),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const LoginPage()),
              (Route<dynamic> route) => false,
        );
      }
      return null;
    }
  }
  void _startNewChat() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const NewChatPage()),
    ).then((_) {
      _fetchInitialData();
    });
  }

  void _createNewGroup() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CreateGroupPage()),
    );

    if (result == true) {
      _webSocketService.requestGroupList(widget.userCode);
    }
  }

  void _pinChat(int index) {
    setState(() {
      final chat = filteredChats[index];
      chat.isPinned = !chat.isPinned;
      chats.sort((a, b) => a.isPinned == b.isPinned ? b.timestamp.compareTo(a.timestamp) : (a.isPinned ? -1 : 1));
      filteredChats = List.from(chats);
    });
  }

  void _pinGroup(int index) {
    setState(() {
      final group = filteredGroups[index];
      group.isPinned = !group.isPinned;
      groups.sort((a, b) => a.isPinned == b.isPinned ? b.timestamp.compareTo(a.timestamp) : (a.isPinned ? -1 : 1));
      filteredGroups = List.from(groups);
    });
  }

  void _deleteChat(int index) {
    setState(() {
      final chat = filteredChats[index];
      chats.removeWhere((c) => c.userCode == chat.userCode);
      filteredChats = List.from(chats);
      _newMessageHighlight.remove(chat.userCode);
      _lastReadTimestamps.remove(chat.userCode);
    });
  }

  void _deleteGroup(int index) {
    setState(() {
      final group = filteredGroups[index];
      groups.removeWhere((g) => g.groupId == group.groupId);
      filteredGroups = List.from(groups);
      _newMessageHighlight.remove(group.groupId);
      _lastReadTimestamps.remove(group.groupId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          _getDisplayName(AppConstants.userName),
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
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
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Row(
              children: [
                Icon(
                  _isConnected ? Icons.wifi : Icons.wifi_off,
                  size: 20,
                  color: Colors.white70,
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.person_outline, size: 24),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Opening profile')),
                    );
                  },
                  tooltip: 'Profile',
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined, size: 24),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Opening settings')),
                    );
                  },
                  tooltip: 'Settings',
                ),
              ],
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(120),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search conversations...',
                    hintStyle: TextStyle(color: Colors.grey[500]),
                    prefixIcon: const Icon(Icons.search, color: Colors.grey),
                    filled: true,
                    fillColor: Colors.grey[100],
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.blue, width: 1),
                    ),
                  ),
                ),
              ),
              Container(
                color: Colors.white,
                child: TabBar(
                  controller: _tabController,
                  labelColor: const Color(0xFF1E88E5),
                  unselectedLabelColor: Colors.grey[600],
                  indicatorColor: const Color(0xFF1E88E5),
                  indicatorWeight: 3,
                  labelStyle: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontWeight: FontWeight.normal,
                    fontSize: 16,
                  ),
                  tabs: const [
                    Tab(text: 'Chats'),
                    Tab(text: 'Groups'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildChatsTab(context),
          _buildGroupsTab(context),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _tabController.index == 0 ? _startNewChat : _createNewGroup,
        backgroundColor: const Color(0xFF1E88E5),
        elevation: 4,
        child: Icon(
          _tabController.index == 0 ? Icons.message : Icons.group_add,
          size: 28,
        ),
      ),
    );
  }

  Widget _buildChatsTab(BuildContext context) {
    if (filteredChats.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No conversations yet',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start a new chat using the button below',
              style: TextStyle(fontSize: 14, color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      controller: _chatScrollController,
      itemCount: filteredChats.length,
      separatorBuilder: (context, index) => Divider(
        height: 1,
        color: Colors.grey[200],
        indent: 80,
      ),
      itemBuilder: (context, index) {
        final chat = filteredChats[index];
        return _buildChatItem(chat, index, isGroup: false);
      },
    );
  }

  Widget _buildGroupsTab(BuildContext context) {
    if (filteredGroups.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.group_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No groups yet',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey[600],
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Create a new group using the button below',
              style: TextStyle(fontSize: 14, color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      controller: _groupScrollController,
      itemCount: filteredGroups.length,
      separatorBuilder: (context, index) => Divider(
        height: 1,
        color: Colors.grey[200],
        indent: 80,
      ),
      itemBuilder: (context, index) {
        final group = filteredGroups[index];
        return _buildChatItem(group, index, isGroup: true);
      },
    );
  }

  Widget _buildChatItem(dynamic item, int index, {required bool isGroup}) {
    String name = isGroup ? (item as GroupItem).displayName : (item as ChatItem).displayName;
    String? photoUrl = isGroup ? null : (item as ChatItem).photoUrl;
    String lastMessage = item.lastMessage;
    DateTime timestamp = item.timestamp;
    int unreadCount = item.unreadCount;
    bool isPinned = item.isPinned;
    String id = isGroup ? (item as GroupItem).groupId : (item as ChatItem).userCode;

    ImageProvider? imageProvider;
    if (photoUrl != null && photoUrl.startsWith('/9j/')) {
      try {
        final bytes = base64Decode(photoUrl);
        imageProvider = MemoryImage(bytes);
      } catch (e) {
        print('Error decoding base64 image: $e');
        imageProvider = null;
      }
    } else if (photoUrl != null && photoUrl.isNotEmpty) {
      imageProvider = NetworkImage(photoUrl);
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: _newMessageHighlight[id] == true ? Colors.blue[50] : Colors.transparent,
      child: InkWell(
        onTap: () => _openChatOrGroup(item, isGroup),
        onLongPress: () => _showContextMenu(context, index, isGroup),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundImage: imageProvider,
                    backgroundColor: imageProvider == null ? _getRandomColor() : null,
                    child: imageProvider == null
                        ? Text(
                      name.isNotEmpty ? name[0].toUpperCase() : 'U',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                      ),
                    )
                        : null,
                  ),
                  if (isPinned)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(
                          color: Color(0xFF1E88E5),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.push_pin,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  if (unreadCount > 0)
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: const BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.fromBorderSide(
                            BorderSide(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.w500,
                              color: unreadCount > 0 ? Colors.black : Colors.black87,
                            ),
                          ),
                        ),
                        Text(
                          _formatTimestamp(timestamp),
                          style: TextStyle(
                            fontSize: 12,
                            color: unreadCount > 0 ? Colors.blue[700] : Colors.grey[500],
                            fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      lastMessage.isNotEmpty ? lastMessage : 'No messages yet',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: unreadCount > 0 ? Colors.black : Colors.grey[600],
                        fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
              if (unreadCount > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1E88E5),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      unreadCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, int index, bool isGroup) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  isGroup
                      ? filteredGroups[index].isPinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin
                      : filteredChats[index].isPinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin,
                  color: Colors.grey[700],
                ),
                title: Text(
                  (isGroup ? filteredGroups[index].isPinned : filteredChats[index].isPinned)
                      ? 'Unpin Conversation'
                      : 'Pin Conversation',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                onTap: () {
                  Navigator.pop(context);
                  isGroup ? _pinGroup(index) : _pinChat(index);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.grey[700]),
                title: const Text(
                  'Delete Conversation',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                onTap: () {
                  Navigator.pop(context);
                  isGroup ? _deleteGroup(index) : _deleteChat(index);
                },
              ),
              ListTile(
                leading: Icon(Icons.notifications_off_outlined, color: Colors.grey[700]),
                title: const Text(
                  'Mute Notifications',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Notifications muted')),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Color _getRandomColor() {
    final random = Random();
    return Color.fromRGBO(
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      1,
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    return DateFormat('HH:mm').format(timestamp);
  }
}

class ChatItem {
  String userCode;
  String displayName;
  String? photoUrl;
  String lastMessage;
  DateTime timestamp;
  int unreadCount;
  bool isPinned;

  ChatItem({
    required this.userCode,
    required this.displayName,
    this.photoUrl,
    required this.lastMessage,
    required this.timestamp,
    required this.unreadCount,
    required this.isPinned,
  });
}

class GroupItem {
  String groupId;
  String displayName;
  String lastMessage;
  DateTime timestamp;
  int unreadCount;
  bool isPinned;

  GroupItem({
    required this.groupId,
    required this.displayName,
    required this.lastMessage,
    required this.timestamp,
    required this.unreadCount,
    required this.isPinned,
  });
}