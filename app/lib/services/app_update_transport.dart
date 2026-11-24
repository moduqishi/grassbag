export 'app_update_transport_stub.dart'
    if (dart.library.io) 'app_update_transport_io.dart'
    if (dart.library.js_interop) 'app_update_transport_web.dart';
