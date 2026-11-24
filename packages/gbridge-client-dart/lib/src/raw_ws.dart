import 'dart:async';

/// Platform-neutral minimal text WebSocket abstraction shared by IO and Web transports
/// so pure-Dart protocol engines (such as stock DSH `/api/remote.mux`) run identically
/// across Android, Desktop, and Web.
abstract class GbridgeRawWebSocket {
  Stream<String> get messages;
  Future<void> get done;
  void sendText(String text);
  Future<void> close([int? code, String? reason]);
}
