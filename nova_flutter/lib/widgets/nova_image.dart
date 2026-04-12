import 'package:flutter/material.dart';

/// Simpele network image wrapper met fallback.
/// Gebruikt Image.network direct — geen cache library nodig.
class NovaImage extends StatelessWidget {
  final String? path;
  final double? width;
  final double? height;
  final BoxFit fit;
  final String baseUrl;

  const NovaImage({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.baseUrl = 'https://image.tmdb.org/t/p/w342',
  });

  @override
  Widget build(BuildContext context) {
    if (path == null || path!.isEmpty) {
      return _placeholder();
    }

    final url = '$baseUrl$path';

    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      loadingBuilder: (_, child, progress) {
        if (progress == null) return child;
        return Container(
          width: width,
          height: height,
          color: const Color(0xFF0f1520),
          child: const Center(
            child: SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00b4d8)),
            ),
          ),
        );
      },
      errorBuilder: (_, __, ___) => _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      width: width,
      height: height,
      color: const Color(0xFF0f1520),
      child: const Center(child: Icon(Icons.movie_outlined, color: Colors.grey, size: 28)),
    );
  }
}
