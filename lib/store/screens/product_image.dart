import 'package:flutter/material.dart';

import '../api.dart';
import '../../theme.dart';

/// A product's picture: the API photo when there is one, drawn over the
/// bundled category tile. The tile is what shows while the photo is in
/// flight and if it never arrives, so a slow or dead network costs realism,
/// never a spinner or a broken image.
///
/// Photos load through Flutter's own image client, not the SDK's
/// `IncidentHttpClient`, so they never crowd the catalogue requests out of
/// the network collector's last-20 window.
class ProductImage extends StatelessWidget {
  const ProductImage(
    this.product, {
    super.key,
    required this.width,
    required this.height,
  });

  final Product product;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final tile = Image.asset(
      product.imageAsset,
      width: width,
      height: height,
      fit: BoxFit.cover,
    );
    final url = product.photoUrl;
    if (url == null) return tile;
    return Image.network(
      url,
      width: width,
      height: height,
      // The photos are cut-outs on transparency; contain keeps the whole
      // product in frame on a light well rather than cropping it.
      fit: BoxFit.contain,
      frameBuilder: (context, child, frame, _) => frame == null
          ? tile
          : ColoredBox(color: NimbusTokens.surfaceContainer, child: child),
      errorBuilder: (context, error, stack) => tile,
    );
  }
}
