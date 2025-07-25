import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:hex/hex.dart';
import 'package:pointycastle/export.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:bech32/bech32.dart';

import '../models/account.dart';
import '../models/post_result.dart';
import '../models/platform_type.dart';
import 'error_handler.dart';
import 'social_platform_service.dart';

/// Service for interacting with Nostr relays
class NostrService extends SocialPlatformService {
  final Map<String, WebSocketChannel> _activeConnections = {};
  final Random _random = Random.secure();
  final ErrorHandler _errorHandler = ErrorHandler();
  List<String> _relays;

  /// Initialize with custom relays or use defaults
  NostrService({List<String>? relays}) : _relays = relays ?? defaultRelays;

  @override
  PlatformType get platformType => PlatformType.nostr;

  @override
  List<String> get requiredCredentialFields => ['private_key'];

  /// Current relays being used
  List<String> get relays => _relays;

  /// Update the relays used by this service
  void updateRelays(List<String> newRelays) {
    _relays = newRelays.isNotEmpty ? newRelays : defaultRelays;
    print('NostrService: Updated relays to: ${_relays.join(', ')}');
  }

  /// Optional credential fields that may be present
  static const List<String> optionalCredentialFields = [
    'public_key',
    'display_name',
  ];

  /// Default Nostr relays to use if none are specified
  static const List<String> defaultRelays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.snort.social',
    'wss://relay.nostr.band',
  ];

  @override
  Future<bool> authenticate(Account account) async {
    try {
      if (!hasRequiredCredentials(account)) {
        final error = SocialPlatformException(
          platform: platformType,
          errorType: PostErrorType.invalidCredentials,
          message:
              'Missing required credentials: ${requiredCredentialFields.join(', ')}',
        );
        _errorHandler.logError(
          'Nostr authentication',
          error,
          context: {'account_id': account.id},
          platform: platformType,
        );
        throw error;
      }

      final rawPrivateKey = account.getCredential<String>('private_key')!;
      final privateKeyHex = _convertToHex(rawPrivateKey);

      // Use instance relays (from settings) instead of account-specific relays
      final relays = _relays;

      // Validate private key format
      if (!_isValidPrivateKey(privateKeyHex)) {
        final error = SocialPlatformException(
          platform: platformType,
          errorType: PostErrorType.invalidCredentials,
          message: 'Invalid private key format',
        );
        _errorHandler.logError(
          'Nostr authentication',
          error,
          context: {'account_id': account.id},
          platform: platformType,
        );
        throw error;
      }

      // Test connection to at least one relay
      bool anyRelayConnected = false;
      final connectionErrors = <String>[];
      for (final relay in relays.take(3)) {
        // Test first 3 relays
        try {
          final connected = await _testRelayConnection(relay);
          if (connected) {
            anyRelayConnected = true;
            break;
          } else {
            connectionErrors.add('Failed to connect to $relay');
          }
        } catch (e) {
          connectionErrors.add('Error connecting to $relay: ${e.toString()}');
          continue;
        }
      }

      if (!anyRelayConnected) {
        final error = SocialPlatformException(
          platform: platformType,
          errorType: PostErrorType.networkError,
          message: 'Unable to connect to any Nostr relays',
        );
        _errorHandler.logError(
          'Nostr authentication',
          error,
          context: {
            'account_id': account.id,
            'tested_relays': relays.take(3).toList(),
            'connection_errors': connectionErrors,
          },
          platform: platformType,
        );
        throw error;
      }

      return true;
    } catch (e, stackTrace) {
      if (e is SocialPlatformException) {
        _errorHandler.logError(
          'Nostr authentication',
          e,
          stackTrace: stackTrace,
          context: {'account_id': account.id},
          platform: platformType,
        );
        rethrow;
      }
      final error = SocialPlatformException(
        platform: platformType,
        errorType: PostErrorType.authenticationError,
        message: 'Authentication failed: ${e.toString()}',
        originalError: e,
      );
      _errorHandler.logError(
        'Nostr authentication',
        error,
        stackTrace: stackTrace,
        context: {'account_id': account.id},
        platform: platformType,
      );
      throw error;
    }
  }

  @override
  Future<PostResult> publishPost(String content, Account account) async {
    try {
      // Validate content length
      if (!isContentValid(content)) {
        final result = createFailureResult(
          content,
          'Content exceeds character limit of $characterLimit',
          PostErrorType.contentTooLong,
        );
        _errorHandler.logError(
          'Nostr post validation',
          'Content too long: ${content.length} > $characterLimit',
          context: {
            'account_id': account.id,
            'content_length': content.length,
            'character_limit': characterLimit,
          },
          platform: platformType,
        );
        return result;
      }

      // Check if required credential fields exist
      for (final field in requiredCredentialFields) {
        if (!account.hasCredential(field)) {
          final result = createFailureResult(
            content,
            'Missing required credentials: ${requiredCredentialFields.join(', ')}',
            PostErrorType.invalidCredentials,
          );
          _errorHandler.logError(
            'Nostr post credentials',
            'Missing required credentials',
            context: {
              'account_id': account.id,
              'required_fields': requiredCredentialFields,
              'missing_field': field,
            },
            platform: platformType,
          );
          return result;
        }
      }

      final rawPrivateKey = account.getCredential<String>('private_key')!;
      final privateKeyHex = _convertToHex(rawPrivateKey);

      // Use instance relays (from settings) instead of account-specific relays
      final relays = _relays;

      print('NostrService: Using relays for posting: ${relays.join(', ')}');

      // Validate private key format
      if (!_isValidPrivateKey(privateKeyHex)) {
        final result = createFailureResult(
          content,
          'Invalid private key format',
          PostErrorType.invalidCredentials,
        );
        _errorHandler.logError(
          'Nostr post validation',
          'Invalid private key format',
          context: {'account_id': account.id},
          platform: platformType,
        );
        return result;
      }

      // Validate platform type
      if (account.platform != platformType) {
        final result = createFailureResult(
          content,
          'Invalid platform type',
          PostErrorType.invalidCredentials,
        );
        _errorHandler.logError(
          'Nostr post validation',
          'Invalid platform type',
          context: {
            'account_id': account.id,
            'expected_platform': platformType.id,
            'actual_platform': account.platform.id,
          },
          platform: platformType,
        );
        return result;
      }

      // Generate public key from private key
      final publicKeyHex = _getPublicKeyFromPrivate(privateKeyHex);

      // Create Nostr event
      final event = _createTextNoteEvent(
        content: content,
        privateKeyHex: privateKeyHex,
        publicKeyHex: publicKeyHex,
      );

      // Publish to relays
      int successCount = 0;
      final errors = <String>[];

      print(
        'Starting to publish to ${relays.length} relays: ${relays.join(', ')}',
      );

      for (final relay in relays) {
        try {
          print('Attempting to publish to $relay');
          final success = await _publishToRelay(relay, event);
          if (success) {
            successCount++;
            print('Successfully published to $relay');
          } else {
            errors.add('Failed to publish to $relay');
            print('Failed to publish to $relay');
          }
        } catch (e) {
          errors.add('Error publishing to $relay: ${e.toString()}');
          print('Error publishing to $relay: ${e.toString()}');
        }
      }

      print(
        'Publishing complete. Success count: $successCount, Errors: ${errors.join(', ')}',
      );

      // Consider successful if published to at least one relay
      if (successCount > 0) {
        _errorHandler.logError(
          'Nostr post success',
          'Successfully published to $successCount of ${relays.length} relays',
          context: {
            'account_id': account.id,
            'success_count': successCount,
            'total_relays': relays.length,
            'errors': errors,
          },
          platform: platformType,
        );
        return createSuccessResult(content);
      } else {
        final result = createFailureResult(
          content,
          'Failed to publish to any relays. Errors: ${errors.join(', ')}',
          PostErrorType.networkError,
        );
        _errorHandler.logError(
          'Nostr post failure',
          'Failed to publish to any relays',
          context: {
            'account_id': account.id,
            'total_relays': relays.length,
            'errors': errors,
            'tested_relays': relays,
          },
          platform: platformType,
        );
        return result;
      }
    } on SocketException catch (e, stackTrace) {
      final result = createFailureResult(
        content,
        'Network connection failed',
        PostErrorType.networkError,
      );
      _errorHandler.logError(
        'Nostr post network error',
        e,
        stackTrace: stackTrace,
        context: {'account_id': account.id},
        platform: platformType,
      );
      return result;
    } catch (e, stackTrace) {
      final result = handleError(content, e);
      _errorHandler.logError(
        'Nostr post unexpected error',
        e,
        stackTrace: stackTrace,
        context: {'account_id': account.id},
        platform: platformType,
      );
      return result;
    }
  }

  @override
  Future<bool> validateConnection(Account account) async {
    try {
      return await authenticate(account);
    } catch (e) {
      return false;
    }
  }

  @override
  bool validateCredentials(Account account) {
    if (!super.validateCredentials(account)) return false;

    final rawPrivateKey = account.getCredential<String>('private_key');
    final relays = account.getCredential<List<String>>('relays');

    // Validate private key format
    if (rawPrivateKey == null) return false;
    
    try {
      final hexKey = _convertToHex(rawPrivateKey);
      if (!_isValidPrivateKey(hexKey)) return false;
    } catch (e) {
      return false; // Invalid key format that throws exception during conversion
    }

    // Validate relays format
    if (relays != null) {
      for (final relay in relays) {
        if (!_isValidRelayUrl(relay)) return false;
      }
    }

    return true;
  }

  /// Generate a new Nostr key pair
  ///
  /// Returns a map containing 'private_key' and 'public_key' in hex format.
  static Map<String, String> generateKeyPair() {
    final random = Random.secure();
    final privateKeyBytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      privateKeyBytes[i] = random.nextInt(256);
    }

    final privateKeyHex = HEX.encode(privateKeyBytes);
    final publicKeyHex = _getPublicKeyFromPrivate(privateKeyHex);

    return {'private_key': privateKeyHex, 'public_key': publicKeyHex};
  }

  /// Get public key from private key
  static String _getPublicKeyFromPrivate(String privateKeyHex) {
    final privateKeyBytes = HEX.decode(privateKeyHex);

    // Create secp256k1 domain parameters
    final domainParams = ECDomainParameters('secp256k1');

    // Create private key
    final privateKey = ECPrivateKey(
      BigInt.parse(HEX.encode(privateKeyBytes), radix: 16),
      domainParams,
    );

    // Calculate public key point
    final publicKeyPoint = domainParams.G * privateKey.d!;

    // BIP-340: Use x-coordinate only, ensure it represents even y
    final xCoordinate = publicKeyPoint!.x!.toBigInteger()!;

    // For BIP-340, we need the x-coordinate of the point with even y
    // If y is odd, we don't negate (that's only for signing), we just use x as is
    // since Nostr public keys are just the x-coordinate

    return xCoordinate.toRadixString(16).padLeft(64, '0');
  }

  /// Create a text note event (kind 1)
  Map<String, dynamic> _createTextNoteEvent({
    required String content,
    required String privateKeyHex,
    required String publicKeyHex,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    print('Creating text note event:');
    print(
      '  Content: ${content.length > 50 ? '${content.substring(0, 50)}...' : content}',
    );
    print('  Public key: $publicKeyHex');
    print('  Timestamp: $now');

    // Create event without signature
    final event = {
      'kind': 1,
      'created_at': now,
      'tags': <List<String>>[],
      'content': content,
      'pubkey': publicKeyHex,
    };

    print('  Event before signing: ${jsonEncode(event)}');

    // Create event ID and signature
    final eventId = _calculateEventId(event);
    final signature = _signEvent(eventId, privateKeyHex);

    // Add ID and signature to event
    event['id'] = eventId;
    event['sig'] = signature;

    print('  Final event: ${jsonEncode(event)}');

    return event;
  }

  /// Calculate event ID according to NIP-01
  String _calculateEventId(Map<String, dynamic> event) {
    // Create serialized event for hashing
    final serialized = [
      0, // Reserved for future use
      event['pubkey'],
      event['created_at'],
      event['kind'],
      event['tags'],
      event['content'],
    ];

    final jsonString = jsonEncode(serialized);
    final bytes = utf8.encode(jsonString);
    final digest = sha256.convert(bytes);

    return HEX.encode(digest.bytes);
  }

  /// Sign event with private key using BIP-340 Schnorr signatures
  String _signEvent(String eventId, String privateKeyHex) {
    final eventIdBytes = Uint8List.fromList(HEX.decode(eventId));

    print('Signing event ID: $eventId');
    print('Private key (first 8 chars): ${privateKeyHex.substring(0, 8)}...');

    // Create secp256k1 domain parameters
    final domainParams = ECDomainParameters('secp256k1');

    // Create private key
    final privateKeyInt = BigInt.parse(privateKeyHex, radix: 16);

    // Ensure private key is in valid range [1, n-1]
    if (privateKeyInt <= BigInt.zero || privateKeyInt >= domainParams.n) {
      throw Exception('Invalid private key: out of valid range');
    }

    print(
      'Private key BigInt: ${privateKeyInt.toString().substring(0, 10)}...',
    );

    // BIP-340 Schnorr signature implementation

    // Generate deterministic nonce k
    final auxBytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      auxBytes[i] = _random.nextInt(256);
    }

    // Create nonce using BIP-340 method: k = H(d || aux) where d is private key
    final nonceInput = <int>[];
    nonceInput.addAll(HEX.decode(privateKeyHex));
    nonceInput.addAll(auxBytes);
    final nonceHash = sha256.convert(nonceInput);
    var k = BigInt.parse(HEX.encode(nonceHash.bytes), radix: 16);

    // Ensure k is in valid range [1, n-1]
    k = (k % (domainParams.n - BigInt.one)) + BigInt.one;

    // Calculate R = k * G
    var R = domainParams.G * k;
    var rX = R!.x!.toBigInteger()!;
    var rY = R.y!.toBigInteger()!;

    print(
      'Initial R: (${rX.toRadixString(16).substring(0, 16)}..., ${rY.toRadixString(16).substring(0, 16)}...)',
    );

    // BIP-340 requirement: R.y must be even (quadratic residue)
    // If R.y is odd, negate k and recalculate R
    if (rY.isOdd) {
      k = domainParams.n - k;
      R = domainParams.G * k;
      rX = R!.x!.toBigInteger()!;
      rY = R.y!.toBigInteger()!;
      print(
        'Negated k, new R: (${rX.toRadixString(16).substring(0, 16)}..., ${rY.toRadixString(16).substring(0, 16)}...)',
      );
    }

    // Get public key point
    final publicKeyPoint = domainParams.G * privateKeyInt;
    final publicKeyX = publicKeyPoint!.x!.toBigInteger()!;

    print('Public key X: ${publicKeyX.toRadixString(16).substring(0, 16)}...');

    // BIP-340 challenge: e = H("BIP0340/challenge" || R_x || P_x || m)
    final challengeInput = <int>[];

    // Add BIP-340 challenge tag
    final challengeTag = utf8.encode("BIP0340/challenge");
    final tagHash = sha256.convert(challengeTag);
    challengeInput.addAll(tagHash.bytes);
    challengeInput.addAll(tagHash.bytes);

    challengeInput.addAll(_bigIntToBytes(rX, 32));
    challengeInput.addAll(_bigIntToBytes(publicKeyX, 32));
    challengeInput.addAll(eventIdBytes);

    final challengeHash = sha256.convert(challengeInput);
    final e =
        BigInt.parse(HEX.encode(challengeHash.bytes), radix: 16) %
        domainParams.n;

    print('Challenge e: ${e.toRadixString(16).substring(0, 16)}...');

    // Calculate signature: s = k + e * d (mod n)
    final s = (k + (e * privateKeyInt)) % domainParams.n;

    print('Signature r (R.x): ${rX.toRadixString(16).substring(0, 16)}...');
    print('Signature s: ${s.toRadixString(16).substring(0, 16)}...');

    // BIP-340 signature format: 32 bytes r (R.x) + 32 bytes s
    final rHex = rX.toRadixString(16).padLeft(64, '0');
    final sHex = s.toRadixString(16).padLeft(64, '0');
    final finalSignature = rHex + sHex;

    print(
      'Final signature (first 16 chars): ${finalSignature.substring(0, 16)}...',
    );
    print('Final signature length: ${finalSignature.length}');

    return finalSignature;
  }

  /// Convert BigInt to byte array with specified length
  Uint8List _bigIntToBytes(BigInt value, int length) {
    final hex = value.toRadixString(16).padLeft(length * 2, '0');
    return Uint8List.fromList(HEX.decode(hex));
  }

  /// Test connection to a relay
  Future<bool> _testRelayConnection(String relayUrl) async {
    try {
      print('Testing connection to $relayUrl');
      final channel = WebSocketChannel.connect(Uri.parse(relayUrl));

      // Wait for connection or timeout
      await channel.ready.timeout(const Duration(seconds: 5));
      print('Connected to $relayUrl successfully');

      // Send a simple REQ message to test the connection
      final reqMessage = jsonEncode([
        'REQ',
        _generateSubscriptionId(),
        {
          'kinds': [1],
          'limit': 1,
        },
      ]);

      channel.sink.add(reqMessage);
      print('Sent REQ message to $relayUrl');

      // Wait for any response or timeout
      await channel.stream.first.timeout(const Duration(seconds: 3));
      print('Received response from $relayUrl');

      // Close connection
      await channel.sink.close(status.normalClosure);

      return true;
    } catch (e) {
      print('Failed to connect to $relayUrl: $e');
      return false;
    }
  }

  /// Publish event to a specific relay
  Future<bool> _publishToRelay(
    String relayUrl,
    Map<String, dynamic> event,
  ) async {
    try {
      print('Publishing to $relayUrl');
      final channel = WebSocketChannel.connect(Uri.parse(relayUrl));

      // Wait for connection
      await channel.ready.timeout(const Duration(seconds: 10));
      print('Connected to $relayUrl for publishing');

      // Send EVENT message
      final eventMessage = jsonEncode(['EVENT', event]);
      channel.sink.add(eventMessage);
      print('Sent EVENT message to $relayUrl');

      // Wait for OK response
      bool success = false;
      await for (final message in channel.stream.timeout(
        const Duration(seconds: 10),
      )) {
        print('Received message from $relayUrl: $message');
        final data = jsonDecode(message as String) as List<dynamic>;

        if (data.length >= 3 && data[0] == 'OK' && data[1] == event['id']) {
          success = data[2] as bool;
          print('Received OK response from $relayUrl: $success');
          if (data.length >= 4 && !success) {
            print('Error message from $relayUrl: ${data[3]}');
          }
          break;
        }
      }

      // Close connection
      await channel.sink.close(status.normalClosure);
      print('Closed connection to $relayUrl, success: $success');

      return success;
    } catch (e) {
      print('Failed to publish to $relayUrl: $e');
      return false;
    }
  }

  /// Generate a random subscription ID
  String _generateSubscriptionId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return String.fromCharCodes(
      Iterable.generate(
        16,
        (_) => chars.codeUnitAt(_random.nextInt(chars.length)),
      ),
    );
  }

  /// Validate private key format (64 character hex string)
  bool _isValidPrivateKey(String privateKey) {
    // Handle nsec format (bech32 encoded)
    if (privateKey.startsWith('nsec')) {
      try {
        // For now, just check if it's reasonable length for nsec
        return privateKey.length >= 59 && privateKey.length <= 65;
      } catch (e) {
        return false;
      }
    }

    // Handle hex format
    if (privateKey.length != 64) return false;

    try {
      HEX.decode(privateKey);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Convert private key to hex format (handles both nsec and hex inputs)
  String _convertToHex(String privateKey) {
    print('Converting private key to hex, input length: ${privateKey.length}');
    print('Private key starts with: ${privateKey.substring(0, 4)}');

    if (privateKey.startsWith('nsec')) {
      print('Processing as nsec format');

      try {
        // Decode the bech32 nsec key
        final decoded = bech32.decode(privateKey);
        if (decoded.hrp != 'nsec') {
          throw SocialPlatformException(
            platform: platformType,
            errorType: PostErrorType.invalidCredentials,
            message: 'Invalid nsec format: expected "nsec" prefix',
          );
        }

        // Convert 5-bit data to 8-bit bytes using our helper
        final converted = _convertBits(decoded.data, 5, 8, false);
        if (converted.length != 32) {
          throw SocialPlatformException(
            platform: platformType,
            errorType: PostErrorType.invalidCredentials,
            message: 'Invalid nsec format: incorrect key length after decoding',
          );
        }

        // Convert bytes to hex string
        final hexKey = HEX.encode(converted);
        print('Successfully converted nsec to hex, length: ${hexKey.length}');
        return hexKey;
      } catch (e) {
        print('Error converting nsec to hex: $e');
        throw SocialPlatformException(
          platform: platformType,
          errorType: PostErrorType.invalidCredentials,
          message: 'Failed to decode nsec private key: ${e.toString()}',
        );
      }
    }

    print('Processing as hex format');
    // Handle hex format - must be exactly 64 hex characters
    String hexKey = privateKey.toLowerCase().replaceAll(
      RegExp(r'[^0-9a-f]'),
      '',
    );
    
    // Validate hex key length
    if (hexKey.length != 64) {
      throw SocialPlatformException(
        platform: platformType,
        errorType: PostErrorType.invalidCredentials,
        message: 'Private key must be exactly 64 hex characters, got ${hexKey.length}',
      );
    }

    print('Final hex key length: ${hexKey.length}');
    return hexKey;
  }

  /// Convert between bit groups (helper for bech32 decoding)
  List<int> _convertBits(List<int> data, int fromBits, int toBits, bool pad) {
    int acc = 0;
    int bits = 0;
    List<int> ret = [];
    int maxv = (1 << toBits) - 1;
    int maxAcc = (1 << (fromBits + toBits - 1)) - 1;

    for (int value in data) {
      if (value < 0 || value >> fromBits != 0) {
        throw Exception('Invalid data for base conversion');
      }
      acc = ((acc << fromBits) | value) & maxAcc;
      bits += fromBits;
      while (bits >= toBits) {
        bits -= toBits;
        ret.add((acc >> bits) & maxv);
      }
    }

    if (pad) {
      if (bits > 0) {
        ret.add((acc << (toBits - bits)) & maxv);
      }
    } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0) {
      throw Exception('Invalid padding in conversion');
    }

    return ret;
  }

  /// Validate relay URL format
  bool _isValidRelayUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.scheme == 'wss' || uri.scheme == 'ws';
    } catch (e) {
      return false;
    }
  }

  /// Close all active WebSocket connections
  void dispose() {
    for (final connection in _activeConnections.values) {
      connection.sink.close(status.normalClosure);
    }
    _activeConnections.clear();
  }

  /// Static method to convert nsec to hex (for UI use)
  static String? convertNsecToHex(String nsecKey) {
    try {
      if (!nsecKey.startsWith('nsec')) {
        return null; // Not an nsec key
      }

      // Decode the bech32 nsec key
      final decoded = bech32.decode(nsecKey);
      if (decoded.hrp != 'nsec') {
        return null; // Invalid format
      }

      // Convert 5-bit data to 8-bit bytes using helper
      final converted = _convertBitsStatic(decoded.data, 5, 8, false);
      if (converted.length != 32) {
        return null; // Invalid key length
      }

      // Convert bytes to hex string
      return HEX.encode(converted);
    } catch (e) {
      return null; // Conversion failed
    }
  }

  /// Static helper for bit conversion
  static List<int> _convertBitsStatic(
    List<int> data,
    int fromBits,
    int toBits,
    bool pad,
  ) {
    int acc = 0;
    int bits = 0;
    List<int> ret = [];
    int maxv = (1 << toBits) - 1;
    int maxAcc = (1 << (fromBits + toBits - 1)) - 1;

    for (int value in data) {
      if (value < 0 || value >> fromBits != 0) {
        throw Exception('Invalid data for base conversion');
      }
      acc = ((acc << fromBits) | value) & maxAcc;
      bits += fromBits;
      while (bits >= toBits) {
        bits -= toBits;
        ret.add((acc >> bits) & maxv);
      }
    }

    if (pad) {
      if (bits > 0) {
        ret.add((acc << (toBits - bits)) & maxv);
      }
    } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0) {
      throw Exception('Invalid padding in conversion');
    }

    return ret;
  }
}
