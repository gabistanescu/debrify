import 'package:flutter/material.dart';
import '../services/debrid_service.dart';
import '../utils/file_utils.dart';
import '../utils/formatters.dart';

/// Unified file selection dialog used across the app for selecting files from a torrent.
/// This is used in:
/// - Torrent Search Screen (when adding a new torrent)
/// - Real-Debrid Downloads Screen (when editing an existing torrent)
class FileSelectionDialog extends StatefulWidget {
  final String torrentId;
  final String torrentName;
  final List<dynamic> files;
  final String apiKey;
  final bool? isCached; // Optional - for display purposes only

  const FileSelectionDialog({
    super.key,
    required this.torrentId,
    required this.torrentName,
    required this.files,
    required this.apiKey,
    this.isCached,
  });

  @override
  State<FileSelectionDialog> createState() => _FileSelectionDialogState();
}

class _FileSelectionDialogState extends State<FileSelectionDialog> {
  final Set<int> _selectedFileIds = {};
  bool _selectAll = true;
  List<dynamic> _sortedFiles = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    
    // Group files by folder
    final Map<String, List<dynamic>> folderGroups = {};
    for (final file in widget.files) {
      final path = file['path'] as String? ?? '';
      final parts = path.split('/');
      final folder = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
      
      if (!folderGroups.containsKey(folder)) {
        folderGroups[folder] = [];
      }
      folderGroups[folder]!.add(file);
    }
    
    // Sort folders by name (natural sort)
    final sortedFolders = folderGroups.keys.toList()..sort((a, b) => _naturalCompare(a, b));
    
    // Sort files within each folder and build final sorted list
    _sortedFiles = [];
    for (final folder in sortedFolders) {
      final filesInFolder = folderGroups[folder]!;
      // Sort files by name within the folder (natural sort)
      filesInFolder.sort((a, b) {
        final nameA = (a['path'] as String?)?.split('/').last ?? '';
        final nameB = (b['path'] as String?)?.split('/').last ?? '';
        return _naturalCompare(nameA, nameB);
      });
      _sortedFiles.addAll(filesInFolder);
    }
    
    // Select all files by default
    for (final file in widget.files) {
      _selectedFileIds.add(file['id'] as int);
    }
    _selectAll = true;
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

  void _toggleSelectAll() {
    setState(() {
      if (_selectAll) {
        _selectedFileIds.clear();
      } else {
        _selectedFileIds.clear();
        for (final file in widget.files) {
          _selectedFileIds.add(file['id'] as int);
        }
      }
      _selectAll = !_selectAll;
    });
  }

  void _selectOnlyVideoFiles() {
    setState(() {
      _selectedFileIds.clear();
      for (final file in widget.files) {
        final fileName = (file['name'] as String?)?.isNotEmpty == true
            ? file['name'] as String
            : FileUtils.getFileName(file['path'] as String? ?? '');
        if (fileName.isNotEmpty && FileUtils.isVideoFile(fileName)) {
          _selectedFileIds.add(file['id'] as int);
        }
      }
      _selectAll = _selectedFileIds.length == widget.files.length;
    });
  }

  void _selectOnlySubtitles() {
    setState(() {
      _selectedFileIds.clear();
      for (final file in widget.files) {
        final fileName = (file['name'] as String?)?.isNotEmpty == true
            ? file['name'] as String
            : FileUtils.getFileName(file['path'] as String? ?? '');
        if (fileName.isNotEmpty && FileUtils.isSubtitleFile(fileName)) {
          _selectedFileIds.add(file['id'] as int);
        }
      }
      _selectAll = _selectedFileIds.length == widget.files.length;
    });
  }

  Future<void> _addToRealDebrid() async {
    if (_selectedFileIds.isEmpty) return;

    // Save messenger before closing dialog
    final messenger = ScaffoldMessenger.of(context);
    
    // Close file selection dialog first with true (files added successfully)
    if (mounted) {
      Navigator.of(context).pop(true);
    }

    try {
      // Select files
      await DebridService.selectFiles(
        widget.apiKey,
        widget.torrentId,
        _selectedFileIds.toList(),
      );

      // Show success message
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.download, color: Colors.white, size: 16),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Torrent added with selected files!',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF1E293B),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      // Show error
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.error, color: Colors.white, size: 16),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Failed to add torrent: ${e.toString()}',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF1E293B),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1E293B), Color(0xFF334155)],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFF6366F1).withValues(alpha: 0.3),
            width: 2,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                ),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                ),
              ),
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.playlist_add_check,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Select Files',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Cancel',
                  ),
                ],
              ),
            ),

            // Search bar (always visible at top)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2937),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.5),
                    width: 2,
                  ),
                ),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search files...',
                    hintStyle: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                    prefixIcon: const Icon(
                      Icons.search,
                      color: Color(0xFF6366F1),
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(
                              Icons.clear,
                              color: Colors.white70,
                            ),
                            onPressed: () {
                              setState(() {
                                _searchController.clear();
                                _searchQuery = '';
                              });
                            },
                          )
                        : null,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ),

            // Action buttons (Row 2) - Deselect All and Only
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: _toggleSelectAll,
                        icon: Icon(
                          _selectAll ? Icons.check_box : Icons.check_box_outline_blank,
                          size: 18,
                        ),
                        label: Text(_selectAll ? 'Deselect All' : 'Select All'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: PopupMenuButton<String>(
                        offset: const Offset(0, 8),
                        onSelected: (value) {
                          if (value == 'video') {
                            _selectOnlyVideoFiles();
                          } else if (value == 'subtitles') {
                            _selectOnlySubtitles();
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'video',
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.movie, color: Color(0xFF10B981), size: 18),
                                SizedBox(width: 8),
                                Text('Video', style: TextStyle(color: Colors.white)),
                              ],
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'subtitles',
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.subtitles, color: Color(0xFF10B981), size: 18),
                                SizedBox(width: 8),
                                Text('Subtitles', style: TextStyle(color: Colors.white)),
                              ],
                            ),
                          ),
                        ],
                        color: const Color(0xFF1E293B),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                        ),
                        position: PopupMenuPosition.under,
                        child: Container(
                          height: 48,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFF10B981)),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.filter_list, color: Color(0xFF10B981), size: 18),
                              SizedBox(width: 8),
                              Text('Only', style: TextStyle(color: Color(0xFF10B981))),
                              SizedBox(width: 4),
                              Icon(Icons.arrow_drop_down, color: Color(0xFF10B981), size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Stats
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '${_selectedFileIds.length} of ${widget.files.length} files selected',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Files list grouped by folder
            Flexible(
              child: Builder(
                builder: (context) {
                  // Filter files based on search query
                  final filteredFiles = _searchQuery.isEmpty
                      ? _sortedFiles
                      : _sortedFiles.where((file) {
                          final path = file['path'] as String? ?? '';
                          final fileName = (file['name'] as String?)?.isNotEmpty == true
                              ? file['name'] as String
                              : FileUtils.getFileName(path);
                          return fileName.toLowerCase().contains(_searchQuery.toLowerCase());
                        }).toList();

                  return ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: filteredFiles.length,
                    itemBuilder: (context, index) {
                      final file = filteredFiles[index];
                      final path = file['path'] as String? ?? '';
                      final parts = path.split('/');
                      final folder = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
                      
                      // Check if this is the start of a new folder (with safe bounds checking)
                      bool isNewFolder = index == 0;
                      if (index > 0) {
                        final prevPath = filteredFiles[index - 1]['path'] as String? ?? '';
                        final prevParts = prevPath.split('/');
                        final prevFolder = prevParts.length > 1 ? prevParts.sublist(0, prevParts.length - 1).join('/') : '';
                        isNewFolder = prevFolder != folder;
                      }
                      
                      final fileId = file['id'] as int;
                      String fileName = (file['name'] as String?)?.isNotEmpty == true
                          ? file['name'] as String
                          : FileUtils.getFileName(path);
                      if (fileName.isEmpty) fileName = 'Unknown';
                      final fileSize = file['bytes'] as int? ?? 0;
                      final isSelected = _selectedFileIds.contains(fileId);
                      final isVideo = FileUtils.isVideoFile(fileName);

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Folder header
                          if (isNewFolder && folder.isNotEmpty)
                            Padding(
                              padding: EdgeInsets.only(top: index == 0 ? 0 : 16, bottom: 8),
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
                                      folder.split('/').last,
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
                          
                          // File item
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF6366F1).withValues(alpha: 0.15)
                                  : const Color(0xFF1F2937),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF6366F1)
                                    : Colors.white.withValues(alpha: 0.1),
                                width: 2,
                              ),
                            ),
                            child: CheckboxListTile(
                              value: isSelected,
                              onChanged: (bool? value) {
                                setState(() {
                                  if (value == true) {
                                    _selectedFileIds.add(fileId);
                                  } else {
                                    _selectedFileIds.remove(fileId);
                                  }
                                  _selectAll = _selectedFileIds.length == widget.files.length;
                                });
                              },
                              title: Row(
                                children: [
                                  Icon(
                                    isVideo ? Icons.movie : Icons.insert_drive_file,
                                    color: isVideo ? const Color(0xFF10B981) : Colors.white70,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      fileName,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4, left: 28),
                                child: Text(
                                  '${Formatters.formatFileSize(fileSize)} • ${FileUtils.getFileType(fileName)}',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.6),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              activeColor: const Color(0xFF6366F1),
                              checkColor: Colors.white,
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),

            // Footer with action buttons
            Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
                ),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                ),
                border: Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                ),
              ),
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _selectedFileIds.isEmpty ? null : _addToRealDebrid,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                        disabledBackgroundColor: const Color(0xFF6B7280),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        'Add ${_selectedFileIds.length} file${_selectedFileIds.length == 1 ? '' : 's'}',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
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
}
