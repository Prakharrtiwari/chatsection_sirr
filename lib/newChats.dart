// new_chat_page.dart
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'chatScreen.dart';
import 'constants.dart'; // Added import for AppConstants

class NewChatPage extends StatefulWidget {
  const NewChatPage({super.key});

  @override
  State<NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends State<NewChatPage> {
  late Future<List<Map<String, dynamic>>> _usersFuture;
  List<Map<String, dynamic>> _allUsers = [];
  List<Map<String, dynamic>> _filteredUsers = [];
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _usersFuture = fetchUsers();
    _searchController.addListener(_onSearchChanged);
  }

  Future<List<Map<String, dynamic>>> fetchUsers() async {
    const String apiUrl = "http://61.95.220.82/mobileAPI/Prakhar/getUsers.php";
    try {
      final response = await http.get(Uri.parse(apiUrl));
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        if (data['status'] == 'success') {
          final users = List<Map<String, dynamic>>.from(data['data']);
          setState(() {
            _allUsers = users;
            _filteredUsers = users; // Initially, all users are shown
          });
          return users;
        } else {
          throw Exception("API returned status: ${data['status']}");
        }
      } else {
        throw Exception("Failed to load users: HTTP ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Error: $e");
    }
  }

  void _onSearchChanged() {
    setState(() {
      _filteredUsers = _allUsers.where((user) {
        final userName = user['UserName']?.toLowerCase() ?? '';
        final searchQuery = _searchController.text.toLowerCase();
        return userName.contains(searchQuery);
      }).toList();
    });
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Search by name...',
            hintStyle: TextStyle(color: Colors.white70),
            border: InputBorder.none,
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
              icon: const Icon(Icons.clear, color: Colors.white),
              onPressed: () {
                setState(() {
                  _searchController.clear();
                  _filteredUsers = _allUsers;
                });
              },
            )
                : null,
          ),
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF2196F3), Color(0xFF42A5F5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        elevation: 6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _usersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            String errorMessage = snapshot.error.toString();
            String statusCode = 'Unknown';
            final RegExp statusCodeRegExp = RegExp(r'HTTP (\d+)');
            final match = statusCodeRegExp.firstMatch(errorMessage);
            if (match != null) {
              statusCode = match.group(1)!;
            }

            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Colors.red,
                    size: 50,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Failed to Load Users',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.red,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Status Code: $statusCode',
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    errorMessage,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _usersFuture = fetchUsers();
                      });
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2196F3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    child: const Text(
                      'Retry',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            );
          } else if (_filteredUsers.isEmpty && _searchController.text.isEmpty) {
            return const Center(
              child: Text(
                'No Users Found',
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.grey,
                  fontWeight: FontWeight.w500,
                ),
              ),
            );
          } else if (_filteredUsers.isEmpty) {
            return const Center(
              child: Text(
                'No Matching Users',
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.grey,
                  fontWeight: FontWeight.w500,
                ),
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            itemCount: _filteredUsers.length,
            separatorBuilder: (context, index) => Divider(
              height: 1,
              color: Colors.grey.withOpacity(0.3),
              indent: 80,
              endIndent: 16,
            ),
            itemBuilder: (context, index) {
              final user = _filteredUsers[index];
              return _buildUserTile(user, context);
            },
          );
        },
      ),
    );
  }

  Widget _buildUserTile(Map<String, dynamic> user, BuildContext context) {
    final isActive = user['IsUserInactive'] == 'N';
    return InkWell(
      onTap: () {
        // ScaffoldMessenger.of(context).showSnackBar(
        //   SnackBar(content: Text('Starting chat with ${user['UserName']}')),
        // );
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              user: user,
              currentUserCode: AppConstants.userCode,
            ),
          ),
        );
      },
      onLongPress: () => _showUserContextMenu(context, user),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 25,
                  backgroundColor: Colors.grey[300],
                  child: user['UserPhoto'] != null && user['UserPhoto'].isNotEmpty
                      ? ClipOval(
                    child: Image.memory(
                      base64Decode(user['UserPhoto']),
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return Text(
                          user['UserName']?.substring(0, 1).toUpperCase() ?? 'U',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      },
                    ),
                  )
                      : Text(
                    user['UserName']?.substring(0, 1).toUpperCase() ?? 'U',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (isActive)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user['UserName'] ?? 'Unknown',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 17,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Designation: ${user['UserDesignationCode'] ?? 'N/A'}',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user['CompanyEmailID']?.isNotEmpty == true
                        ? user['CompanyEmailID']
                        : user['PersonalMobile']?.isNotEmpty == true
                        ? user['PersonalMobile']
                        : 'No contact info',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showUserContextMenu(BuildContext context, Map<String, dynamic> user) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('View Profile'),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Viewing profile of ${user['UserName']}')),
                );
              },
            ),
            if (user['PersonalMobile']?.isNotEmpty == true)
              ListTile(
                leading: const Icon(Icons.phone),
                title: const Text('Call'),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Calling ${user['PersonalMobile']}')),
                  );
                },
              ),
            if (user['CompanyEmailID']?.isNotEmpty == true)
              ListTile(
                leading: const Icon(Icons.email),
                title: const Text('Email'),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Emailing ${user['CompanyEmailID']}')),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}