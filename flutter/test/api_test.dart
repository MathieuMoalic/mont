import 'package:flutter_test/flutter_test.dart';

// Test the URL normalization and utility functions
// Note: We're testing the logic patterns, not the actual HTTP calls

void main() {
  group('URL normalization', () {
    String normalizeBase(String url) {
      final trimmed = url.trim();
      return trimmed.endsWith('/')
          ? trimmed.substring(0, trimmed.length - 1)
          : trimmed;
    }

    test('removes trailing slash', () {
      expect(normalizeBase('https://example.com/'), 'https://example.com');
    });

    test('leaves URL without trailing slash unchanged', () {
      expect(normalizeBase('https://example.com'), 'https://example.com');
    });

    test('trims whitespace', () {
      expect(normalizeBase('  https://example.com  '), 'https://example.com');
    });

    test('trims whitespace and removes trailing slash', () {
      expect(normalizeBase('  https://example.com/  '), 'https://example.com');
    });

    test('handles URL with path', () {
      expect(
        normalizeBase('https://example.com/api/'),
        'https://example.com/api',
      );
    });

    test('handles URL with path without trailing slash', () {
      expect(
        normalizeBase('https://example.com/api'),
        'https://example.com/api',
      );
    });

    test('handles localhost with port', () {
      expect(normalizeBase('http://localhost:3000/'), 'http://localhost:3000');
    });
  });

  group('Auth header construction', () {
    Map<String, String> buildHeaders(String? token) => {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };

    test('includes Content-Type', () {
      final headers = buildHeaders(null);
      expect(headers['Content-Type'], 'application/json');
    });

    test('includes Authorization when token is set', () {
      final headers = buildHeaders('test-token-123');
      expect(headers['Authorization'], 'Bearer test-token-123');
    });

    test('excludes Authorization when token is null', () {
      final headers = buildHeaders(null);
      expect(headers.containsKey('Authorization'), isFalse);
    });
  });

  group('URI construction', () {
    Uri buildUri(String baseUrl, String path) => Uri.parse('$baseUrl$path');

    test('constructs URI with path', () {
      final uri = buildUri('https://example.com', '/exercises');
      expect(uri.toString(), 'https://example.com/exercises');
    });

    test('constructs URI with path containing ID', () {
      final uri = buildUri('https://example.com', '/workouts/123');
      expect(uri.toString(), 'https://example.com/workouts/123');
    });

    test('constructs URI with nested path', () {
      final uri = buildUri('https://example.com', '/workouts/5/sets/10');
      expect(uri.toString(), 'https://example.com/workouts/5/sets/10');
    });
  });
}
