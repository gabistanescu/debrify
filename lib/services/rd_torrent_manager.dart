import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/rd_torrent.dart';
import 'debrid_service.dart';
import 'storage_service.dart';

/// Service for managing Real Debrid torrents with progress tracking
/// Handles non-cached torrents and monitors download progress
class RDTorrentManager {
  static final RDTorrentManager _instance = RDTorrentManager._internal();
  factory RDTorrentManager() => _instance;
  RDTorrentManager._internal();

  // Map of torrent hash -> torrent info for torrents being tracked
  final Map<String, RDTorrent> _downloadingTorrents = {};
  
  // Map of torrent hash -> listener callbacks
  final Map<String, List<void Function(RDTorrent)>> _listeners = {};
  
  // Track previously completed torrents to avoid duplicate notifications
  final Set<String> _notifiedCompletedTorrents = {};
  
  // Callback for when a torrent finishes downloading
  void Function(RDTorrent)? onTorrentCompleted;
  
  Timer? _pollTimer;
  bool _isPolling = false;
  String? _currentApiKey;

  /// Start monitoring torrents with the given API key
  Future<void> startMonitoring(String apiKey) async {
    _currentApiKey = apiKey;
    
    // Load initial torrents
    await refreshTorrents();
    
    // Start polling every 5 seconds
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isPolling) {
        _refreshInBackground();
      }
    });
  }

  /// Stop monitoring torrents
  void stopMonitoring() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _downloadingTorrents.clear();
    _listeners.clear();
    _currentApiKey = null;
  }

  /// Add a torrent to track by hash
  void trackTorrent(String hash, RDTorrent torrent) {
    _downloadingTorrents[hash.toLowerCase()] = torrent;
    _notifyListeners(hash.toLowerCase(), torrent);
  }

  /// Get a torrent by hash
  RDTorrent? getTorrent(String hash) {
    return _downloadingTorrents[hash.toLowerCase()];
  }

  /// Check if a torrent is being downloaded
  bool isDownloading(String hash) {
    final torrent = _downloadingTorrents[hash.toLowerCase()];
    if (torrent == null) return false;
    
    // Consider downloading if status is not "downloaded" or "error"
    return torrent.status != 'downloaded' && 
           torrent.status != 'error' &&
           torrent.status != 'dead' &&
           torrent.status != 'magnet_error';
  }

  /// Get download progress for a torrent (0-100)
  int getProgress(String hash) {
    final torrent = _downloadingTorrents[hash.toLowerCase()];
    return torrent?.progress ?? 0;
  }

  /// Get status message for a torrent
  String getStatusMessage(String hash) {
    final torrent = _downloadingTorrents[hash.toLowerCase()];
    if (torrent == null) return 'Unknown';
    
    switch (torrent.status) {
      case 'magnet_conversion':
        return 'Converting magnet...';
      case 'waiting_files_selection':
        return 'Waiting for file selection';
      case 'queued':
        return 'Queued';
      case 'downloading':
        return 'Downloading ${torrent.progress}%';
      case 'downloaded':
        return 'Downloaded';
      case 'error':
        return 'Error';
      case 'virus':
        return 'Virus detected';
      case 'magnet_error':
        return 'Magnet error';
      case 'dead':
        return 'Dead torrent';
      default:
        return torrent.status;
    }
  }

  /// Get all torrents being tracked
  List<RDTorrent> getAllTorrents() {
    return _downloadingTorrents.values.toList();
  }

  /// Get only downloading torrents (not completed)
  List<RDTorrent> getDownloadingTorrents() {
    return _downloadingTorrents.values
        .where((t) => t.status != 'downloaded' && 
                     t.status != 'error' &&
                     t.status != 'dead' &&
                     t.status != 'magnet_error')
        .toList();
  }

  /// Add a listener for torrent updates
  void addListener(String hash, void Function(RDTorrent) callback) {
    final key = hash.toLowerCase();
    if (!_listeners.containsKey(key)) {
      _listeners[key] = [];
    }
    _listeners[key]!.add(callback);
  }

  /// Remove a listener
  void removeListener(String hash, void Function(RDTorrent) callback) {
    final key = hash.toLowerCase();
    _listeners[key]?.remove(callback);
    if (_listeners[key]?.isEmpty ?? false) {
      _listeners.remove(key);
    }
  }

  /// Refresh torrents from Real Debrid API
  Future<void> refreshTorrents() async {
    if (_currentApiKey == null) return;

    try {
      final result = await DebridService.getTorrents(
        _currentApiKey!,
        limit: 100,
      );
      
      final torrents = result['torrents'] as List<RDTorrent>;
      
      // Update our map with fresh data
      for (final torrent in torrents) {
        final hash = torrent.hash.toLowerCase();
        final existing = _downloadingTorrents[hash];
        
        // Check if torrent just completed
        if (existing != null && 
            existing.status != 'downloaded' && 
            torrent.status == 'downloaded' &&
            !_notifiedCompletedTorrents.contains(hash)) {
          // Notify completion
          _notifiedCompletedTorrents.add(hash);
          if (onTorrentCompleted != null) {
            onTorrentCompleted!(torrent);
          }
        }
        
        // Only track if it's in our list or if it's actively downloading
        if (existing != null || _isActivelyDownloading(torrent)) {
          _downloadingTorrents[hash] = torrent;
          _notifyListeners(hash, torrent);
        }
      }

      // Remove completed torrents after some time (keep them for 30 seconds after completion)
      _downloadingTorrents.removeWhere((hash, torrent) {
        if (torrent.status == 'downloaded') {
          // Check if it was updated recently (within last 30 seconds)
          try {
            final added = DateTime.parse(torrent.added);
            final ended = torrent.ended != null ? DateTime.parse(torrent.ended!) : null;
            if (ended != null && DateTime.now().difference(ended).inSeconds > 30) {
              _notifiedCompletedTorrents.remove(hash);
              return true; // Remove it
            }
          } catch (e) {
            // If we can't parse dates, keep it for one more cycle
          }
        }
        return false;
      });
    } catch (e) {
      debugPrint('RDTorrentManager: Error refreshing torrents: $e');
    }
  }

  Future<void> _refreshInBackground() async {
    _isPolling = true;
    try {
      await refreshTorrents();
    } finally {
      _isPolling = false;
    }
  }

  void _notifyListeners(String hash, RDTorrent torrent) {
    final callbacks = _listeners[hash];
    if (callbacks != null) {
      for (final callback in callbacks) {
        try {
          callback(torrent);
        } catch (e) {
          debugPrint('RDTorrentManager: Error in listener callback: $e');
        }
      }
    }
  }

  bool _isActivelyDownloading(RDTorrent torrent) {
    return torrent.status != 'downloaded' && 
           torrent.status != 'error' &&
           torrent.status != 'dead' &&
           torrent.status != 'magnet_error';
  }

  /// Remove a torrent from tracking
  void untrackTorrent(String hash) {
    final key = hash.toLowerCase();
    _downloadingTorrents.remove(key);
    _listeners.remove(key);
  }
}
