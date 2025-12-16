import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../services/debrid_service.dart';
import '../services/storage_service.dart';
import '../services/video_player_launcher.dart';
import '../utils/file_utils.dart';
import '../utils/formatters.dart';
import 'video_player_screen.dart';

class PlaylistFileBrowserScreen extends StatefulWidget {
  final Map<String, dynamic> playlistItem;

  const PlaylistFileBrowserScreen({
    super.key,
    required this.playlistItem,
  });

  @override
  State<PlaylistFileBrowserScreen> createState() => _PlaylistFileBrowserScreenState();
}

class _PlaylistFileBrowserScreenState extends State<PlaylistFileBrowserScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<dynamic> _allFiles = [];
  List<dynamic> _allTorrentFiles = [];
  List<dynamic> _links = [];
  Map<int, String> _fileIdToLink = {}; // Map file ID to its restricted link
  bool _isLoading = true;
  String? _error;
  bool _sortAscending = true; // true = A-Z, false = Z-A
  Map<String, dynamic>? _lastPlayedFile;
  List<Widget>? _cachedFileListItems; // Cache for file list items

  String get _playlistId {
    // Use the same dedupe key computation as playlist screen
    return StorageService.computePlaylistDedupeKey(widget.playlistItem);
  }

  @override
  void initState() {
    super.initState();
    _loadFiles();
    _loadLastPlayedFile();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFiles() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final rdTorrentId = widget.playlistItem['rdTorrentId'] as String?;
      if (rdTorrentId == null || rdTorrentId.isEmpty) {
        throw Exception('No torrent ID found');
      }

      final apiKey = await StorageService.getApiKey();
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception('API key not found');
      }

      final torrentInfo = await DebridService.getTorrentInfo(apiKey, rdTorrentId);
      if (torrentInfo == null) {
        throw Exception('Failed to fetch torrent info');
      }

      final files = torrentInfo['files'] as List?;
      final links = torrentInfo['links'] as List?;
      
      if (files == null || files.isEmpty) {
        throw Exception('No files found in torrent');
      }
      
      if (links == null || links.isEmpty) {
        throw Exception('No links found in torrent');
      }

      // Filter only video files and create a mapping to their links
      // IMPORTANT: Real-Debrid returns links ONLY for files where selected=1
      // Links are in the order of selected files, NOT in the order of all files
      final List<dynamic> videoFiles = [];
      final List<String> videoLinks = [];
      final Map<int, String> fileIdToLink = {};
      
      int selectedFileIndex = 0; // Counter for selected files (maps to links array)
      int skippedFiles = 0;
      int nonVideoFiles = 0;
      int videoFilesWithoutLinks = 0;
      
      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        final path = file['path'] as String? ?? '';
        final fileId = file['id'] as int?;
        final selected = file['selected'] as int? ?? 0;
        
        if (FileUtils.isVideoFile(path)) {
          // Check if this file is selected (has a link)
          if (selected == 1) {
            // This file has a link at position selectedFileIndex
            if (selectedFileIndex < links.length) {
              final link = links[selectedFileIndex].toString();
              
              if (link.isNotEmpty && fileId != null) {
                videoFiles.add(file);
                videoLinks.add(link);
                fileIdToLink[fileId] = link;
              } else {
                skippedFiles++;
              }
            }
            selectedFileIndex++; // Increment for next selected file
          } else {
            videoFilesWithoutLinks++;
          }
        } else {
          nonVideoFiles++;
        }
      }
      
      print('Loaded ${fileIdToLink.length} video files with links');
      
      if (fileIdToLink.isEmpty) {
        throw Exception('No video files with download links found. Please ensure files are selected in Real-Debrid.');
      }

      setState(() {
        _allFiles = videoFiles;
        _allTorrentFiles = files; // Keep for reference
        _links = videoLinks; // Only links for video files
        _fileIdToLink = fileIdToLink; // ID to link mapping
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadLastPlayedFile() async {
    try {
      final lastPlayed = await StorageService.getLastPlayedFile(_playlistId);
      if (mounted && lastPlayed != null && lastPlayed.isNotEmpty) {
        // Only set if it has valid data (path exists)
        final path = lastPlayed['path'] as String?;
        if (path != null && path.isNotEmpty) {
          setState(() {
            _lastPlayedFile = lastPlayed;
          });
        }
      }
    } catch (e) {
      // Ignore errors for last played
    }
  }

  List<dynamic> get _filteredAndSortedFiles {
    var files = _allFiles.where((file) {
      if (_searchQuery.isEmpty) return true;
      final path = (file['path'] as String? ?? '').toLowerCase();
      return path.contains(_searchQuery.toLowerCase());
    }).toList();

    // Group files by folder
    final Map<String, List<dynamic>> folderGroups = {};
    for (final file in files) {
      final path = file['path'] as String? ?? '';
      final parts = path.split('/');
      final folder = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
      
      if (!folderGroups.containsKey(folder)) {
        folderGroups[folder] = [];
      }
      folderGroups[folder]!.add(file);
    }
    
    // Sort folders by name (natural sort)
    final sortedFolders = folderGroups.keys.toList()..sort((a, b) {
      return _sortAscending ? _naturalCompare(a, b) : _naturalCompare(b, a);
    });
    
    // Sort files within each folder and build final sorted list
    final List<dynamic> sortedFiles = [];
    for (final folder in sortedFolders) {
      final filesInFolder = folderGroups[folder]!;
      // Sort files by name within the folder (natural sort)
      filesInFolder.sort((a, b) {
        final nameA = (a['path'] as String?)?.split('/').last ?? '';
        final nameB = (b['path'] as String?)?.split('/').last ?? '';
        return _sortAscending ? _naturalCompare(nameA, nameB) : _naturalCompare(nameB, nameA);
      });
      sortedFiles.addAll(filesInFolder);
    }

    return sortedFiles;
  }

  /// Natural sort comparison that handles numbers correctly.
  int _naturalCompare(String a, String b) {
    final RegExp numberPattern = RegExp(r'(\d+)');
    final List<String> aParts = [];
    final List<String> bParts = [];
    
    // Split strings into text and number parts
    int aIndex = 0;
    for (final match in numberPattern.allMatches(a)) {
      if (match.start > aIndex) {
        aParts.add(a.substring(aIndex, match.start));
      }
      aParts.add(match.group(0)!);
      aIndex = match.end;
    }
    if (aIndex < a.length) {
      aParts.add(a.substring(aIndex));
    }
    
    int bIndex = 0;
    for (final match in numberPattern.allMatches(b)) {
      if (match.start > bIndex) {
        bParts.add(b.substring(bIndex, match.start));
      }
      bParts.add(match.group(0)!);
      bIndex = match.end;
    }
    if (bIndex < b.length) {
      bParts.add(b.substring(bIndex));
    }
    
    // Compare parts
    for (int i = 0; i < aParts.length && i < bParts.length; i++) {
      final aPart = aParts[i];
      final bPart = bParts[i];
      
      // Check if both parts are numbers
      final aNum = int.tryParse(aPart);
      final bNum = int.tryParse(bPart);
      
      if (aNum != null && bNum != null) {
        // Compare numerically
        if (aNum != bNum) {
          return aNum.compareTo(bNum);
        }
      } else {
        // Compare lexicographically (case-insensitive)
        final comparison = aPart.toLowerCase().compareTo(bPart.toLowerCase());
        if (comparison != 0) {
          return comparison;
        }
      }
    }
    
    // If all parts match, compare by length
    return aParts.length.compareTo(bParts.length);
  }

  Future<void> _playFile(dynamic file) async {
    try {
      final fileId = file['id'];
      final filePath = file['path'] as String?;
      final rdTorrentId = widget.playlistItem['rdTorrentId'] as String?;
      
      if ((fileId == null && filePath == null) || rdTorrentId == null) {
        throw Exception('Invalid file or torrent ID');
      }

      // Get the sorted file list and current index FIRST
      final sortedFiles = _filteredAndSortedFiles;
      
      // Try to find by ID first, then fall back to path
      int currentIndex = -1;
      if (fileId != null) {
        currentIndex = sortedFiles.indexWhere((f) => f['id'] == fileId);
      }
      
      // If not found by ID, try to find by path
      if (currentIndex == -1 && filePath != null) {
        currentIndex = sortedFiles.indexWhere((f) => f['path'] == filePath);
        // If exact match not found, try matching just the filename
        if (currentIndex == -1) {
          final targetFilename = filePath.split('/').last;
          currentIndex = sortedFiles.indexWhere((f) {
            final fPath = f['path'] as String?;
            return fPath != null && fPath.split('/').last == targetFilename;
          });
        }
      }
      
      if (currentIndex == -1) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not find file in current list')),
        );
        return;
      }
      
      // Use the actual file from sortedFiles to get correct ID
      final actualFile = sortedFiles[currentIndex];

      // Save as last played BEFORE launching video player (for playlist-level tracking)
      await StorageService.saveLastPlayedFile(_playlistId, {
        'path': actualFile['path'],
        'bytes': actualFile['bytes'],
        'id': actualFile['id'],
        'videoIndex': currentIndex,
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Note: Global last played will be saved by video_player_screen.dart after video loads
      
      // Debug logging
      print('Playing file at index $currentIndex of ${sortedFiles.length} (Sort: ${_sortAscending ? "A-Z" : "Z-A"})');
      print('Current file: ${actualFile['path']}');

      final apiKey = await StorageService.getApiKey();
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception('API key not found');
      }

      // Get the restricted link for this file using the file ID
      final actualFileId = actualFile['id'] as int?;
      if (actualFileId == null) {
        throw Exception('File ID not found');
      }
      
      final restrictedLink = _fileIdToLink[actualFileId];
      if (restrictedLink == null || restrictedLink.isEmpty) {
        print('ERROR: File ID $actualFileId not found in mapping!');
        print('File path: ${actualFile['path']}');
        throw Exception('File link not found for file ID: $actualFileId');
      }

      // Unrestrict only the current video
      final unrestrictResult = await DebridService.unrestrictLink(
        apiKey,
        restrictedLink,
      );

      final downloadLink = unrestrictResult['download']?.toString() ?? '';
      if (downloadLink.isEmpty) {
        throw Exception('Failed to unrestrict link');
      }

      // Build playlist with restricted links for lazy resolution
      if (!mounted) return;
      
      final List<PlaylistEntry> playlistEntries = [];
      int actualCurrentIndex = -1; // Track the actual index in playlistEntries
      
      print('Building playlist with ${sortedFiles.length} files (Sort: ${_sortAscending ? "A-Z" : "Z-A"})');
      
      for (int i = 0; i < sortedFiles.length; i++) {
        if (!mounted) return; // Check periodically during large loops
        
        final sortedFile = sortedFiles[i];
        final sortedFileId = sortedFile['id'] as int?;
        
        if (sortedFileId != null) {
          final fileRestrictedLink = _fileIdToLink[sortedFileId];
          
          if (fileRestrictedLink != null && fileRestrictedLink.isNotEmpty) {
            final path = sortedFile['path'] as String? ?? 'Video';
            final bytes = sortedFile['bytes'] as int?;
            final isCurrentFile = sortedFileId == actualFileId; // Compare with actualFileId
            
            // Track the actual index in playlistEntries for the current file
            if (isCurrentFile) {
              actualCurrentIndex = playlistEntries.length;
            }
            
            playlistEntries.add(
              PlaylistEntry(
                url: isCurrentFile ? downloadLink : '', // Only current has unrestricted URL
                title: path,
                restrictedLink: fileRestrictedLink, // Use the mapped link
                sizeBytes: bytes,
                provider: 'realdebrid',
                fileId: sortedFileId, // Save original file ID
              ),
            );
          }
        }
      }
      
      print('Playlist built with ${playlistEntries.length} entries, actual current index: $actualCurrentIndex');
      print('Starting video: ${playlistEntries[actualCurrentIndex].title}');
      if (actualCurrentIndex > 0) {
        print('Previous video would be: ${playlistEntries[actualCurrentIndex - 1].title}');
      }
      if (actualCurrentIndex < playlistEntries.length - 1) {
        print('Next video would be: ${playlistEntries[actualCurrentIndex + 1].title}');
      }
      
      if (actualCurrentIndex == -1) {
        throw Exception('Current file not found in playlist');
      }

      if (playlistEntries.isEmpty) {
        throw Exception('No valid video files found');
      }

      if (!mounted) return;
      
      await VideoPlayerLauncher.push(
        context,
        VideoPlayerLaunchArgs(
          videoUrl: downloadLink,
          title: playlistEntries[actualCurrentIndex].title,
          subtitle: playlistEntries[actualCurrentIndex].sizeBytes != null 
              ? Formatters.formatFileSize(playlistEntries[actualCurrentIndex].sizeBytes!) 
              : null,
          rdTorrentId: rdTorrentId,
          playlistId: _playlistId,
          playlist: playlistEntries,
          startIndex: actualCurrentIndex,
        ),
      );
      
      // Reload ONLY the last played indicator (not full file list)
      if (mounted) {
        // Small delay to avoid callback issues
        await Future.delayed(const Duration(milliseconds: 100));
        if (mounted) {
          await _loadLastPlayedFile();
        }
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.playlistItem['title'] as String? ?? 'Browse Files',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Column(
        children: [
          // Search bar with sort button
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                        _cachedFileListItems = null; // Invalidate cache
                      });
                    },
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search files...',
                      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                      prefixIcon: const Icon(Icons.search, color: Colors.white70, size: 20),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, color: Colors.white70, size: 20),
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _searchQuery = '';
                                  _cachedFileListItems = null; // Invalidate cache
                                });
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF6366F1), width: 2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Sort toggle button
                InkWell(
                  onTap: () {
                    setState(() {
                      _sortAscending = !_sortAscending;
                      _cachedFileListItems = null; // Invalidate cache
                    });
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF6366F1),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _sortAscending ? Icons.sort_by_alpha : Icons.sort_by_alpha,
                          size: 18,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _sortAscending ? 'A-Z' : 'Z-A',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Last played section
          if (_lastPlayedFile != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: InkWell(
                onTap: () => _playFile(_lastPlayedFile),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.play_circle_filled,
                        color: Color(0xFFE50914),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          (_lastPlayedFile!['path'] as String? ?? '').split('/').last,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // File list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF6366F1),
                    ),
                  )
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 48,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Error loading files',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _error!,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: 14,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      )
                    : _filteredAndSortedFiles.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.video_library_outlined,
                                    size: 48,
                                    color: Colors.white.withValues(alpha: 0.5),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _searchQuery.isEmpty
                                        ? 'No video files found'
                                        : 'No files matching "$_searchQuery"',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.7),
                                      fontSize: 16,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: _buildFileListItems().length,
                            itemBuilder: (context, index) {
                              return _buildFileListItems()[index];
                            },
                          ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFileListItems() {
    // Return cached list if available
    if (_cachedFileListItems != null) {
      return _cachedFileListItems!;
    }
    
    // Build the list
    final List<Widget> items = [];
    String? currentFolder;
    
    for (int i = 0; i < _filteredAndSortedFiles.length; i++) {
      final file = _filteredAndSortedFiles[i];
      final path = file['path'] as String? ?? '';
      final parts = path.split('/');
      final folder = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
      
      // Add folder header if it's a new folder
      if (folder != currentFolder) {
        currentFolder = folder;
        if (folder.isNotEmpty) {
          // Show only the last subfolder name
          final folderName = folder.split('/').last;
          items.add(
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 16, bottom: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder,
                    color: Color(0xFF8B5CF6),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      folderName,
                      style: const TextStyle(
                        color: Color(0xFF8B5CF6),
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      }
      
      // Add file item
      items.add(_buildFileItem(file));
    }
    
    // Cache the list
    _cachedFileListItems = items;
    return items;
  }

  Widget _buildFileItem(dynamic file) {
    final path = file['path'] as String? ?? '';
    final bytes = file['bytes'] as int? ?? 0;
    final fileName = path.split('/').last;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        onTap: () => _playFile(file),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Color(0xFF6366F1),
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      Formatters.formatFileSize(bytes),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.6),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                Icons.chevron_right,
                color: Colors.white.withValues(alpha: 0.5),
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
