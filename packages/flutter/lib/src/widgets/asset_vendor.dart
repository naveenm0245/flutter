// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:mojo/core.dart' as core;

import 'basic.dart';
import 'framework.dart';

// Base class for asset resolvers.
abstract class _AssetResolver {
  // Return a resolved asset key for the asset named [name].
  Future<String> resolve(String name);
}

// Asset bundle capable of producing assets via the resolution logic of an
// asset resolver.
//
// Wraps an underlying [AssetBundle] and forwards calls after resolving the
// asset key.
class _ResolvingAssetBundle extends CachingAssetBundle {

  _ResolvingAssetBundle({ this.bundle, this.resolver });
  final AssetBundle bundle;
  final _AssetResolver resolver;

  Map<String, String> _keyCache = <String, String>{};

  Future<core.MojoDataPipeConsumer> load(String key) async {
    if (!_keyCache.containsKey(key))
      _keyCache[key] = await resolver.resolve(key);
    return await bundle.load(_keyCache[key]);
  }
}

// Base class for resolvers that use the asset manifest to retrieve a list
// of asset variants to choose from.
abstract class _VariantAssetResolver extends _AssetResolver {
  _VariantAssetResolver({ this.bundle });
  final AssetBundle bundle;
  // TODO(kgiesing): Ideally, this cache would be on an object with the same
  // lifetime as the asset bundle it wraps. However, that won't matter until we
  // need to change AssetVendors frequently; as of this writing we only have
  // one.
  Map<String, List<String>> _assetManifest;
  Future _initializer;

  Future _loadManifest() async {
    String json = await bundle.loadString("AssetManifest.json");
    _assetManifest = JSON.decode(json);
  }

  Future<String> resolve(String name) async {
    _initializer ??= _loadManifest();
    await _initializer;
    // If there's no asset manifest, just return the main asset always
    if (_assetManifest == null)
      return name;
    // Allow references directly to variants: if the supplied name is not a
    // key, just return it
    List<String> variants = _assetManifest[name];
    if (variants == null)
      return name;
    else
      return chooseVariant(name, variants);
  }

  String chooseVariant(String main, List<String> variants);
}

// Asset resolver that understands how to determine the best match for the
// current device pixel ratio
class _ResolutionAwareAssetResolver extends _VariantAssetResolver {
  _ResolutionAwareAssetResolver({ AssetBundle bundle, this.devicePixelRatio })
    : super(bundle: bundle);

  final double devicePixelRatio;

  static final RegExp extractRatioRegExp = new RegExp(r"/?(\d+(\.\d*)?)x/");

  SplayTreeMap<double, String> _buildMapping(List<String> candidates) {
    SplayTreeMap<double, String> result = new SplayTreeMap<double, String>();
    for (String candidate in candidates) {
      Match match = extractRatioRegExp.firstMatch(candidate);
      if (match != null && match.groupCount > 0) {
        double resolution = double.parse(match.group(1));
        result[resolution] = candidate;
      }
    }
    return result;
  }

  // Return the value for the key in a [SplayTreeMap] nearest the provided key.
  String _findNearest(SplayTreeMap<double, String> candidates, double value) {
    if (candidates.containsKey(value))
      return candidates[value];
    double lower = candidates.lastKeyBefore(value);
    double upper = candidates.firstKeyAfter(value);
    if (lower == null)
      return candidates[upper];
    if (upper == null)
      return candidates[lower];
    if (value > (lower + upper) / 2)
      return candidates[upper];
    else
      return candidates[lower];
  }

  String chooseVariant(String main, List<String> candidates) {
    SplayTreeMap<double, String> mapping = _buildMapping(candidates);
    // We assume the main asset is designed for a device pixel ratio of 1.0
    mapping[1.0] = main;
    return _findNearest(mapping, devicePixelRatio);
  }
}

/// Establishes an asset resolution strategy for its descendants.
///
/// Given a main asset and a set of variants, AssetVendor chooses the most
/// appropriate asset for the current context. The current asset resolution
/// strategy knows how to find the asset most closely matching the current
/// device pixel ratio, as given by [MediaQueryData].
///
/// Main assets are presumed to match a nominal pixel ratio of 1.0. To specify
/// assets targeting different pixel ratios, place the variant assets in
/// the application bundle under subdirectories named in the form "Nx", where
/// N is the nominal device pixel ratio for that asset.
///
/// For example, suppose an application wants to use an icon named
/// "heart.png". This icon has representations at 1.0 (the main icon), as well
/// as 1.5 and 2.0 pixel ratios (variants). The asset bundle should then contain
/// the following assets:
///
/// heart.png
/// 1.5x/heart.png
/// 2.0x/heart.png
///
/// On a device with a 1.0 device pixel ratio, the image chosen would be
/// heart.png; on a device with a 1.3 device pixel ratio, the image chosen
/// would be 1.5x/heart.png.
///
/// The directory level of the asset does not matter as long as the variants are
/// at the equivalent level; that is, the following is also a valid bundle
/// structure:
///
/// icons/heart.png
/// icons/1.5x/heart.png
/// icons/2.0x/heart.png
class AssetVendor extends StatefulComponent {
  AssetVendor({
    Key key,
    this.bundle,
    this.devicePixelRatio,
    this.child
  }) : super(key: key);

  final AssetBundle bundle;
  final double devicePixelRatio;
  final Widget child;

  _AssetVendorState createState() => new _AssetVendorState();
}

class _AssetVendorState extends State<AssetVendor> {

  _ResolvingAssetBundle _bundle;

  void initState() {
    super.initState();
    _bundle = new _ResolvingAssetBundle(
      bundle: config.bundle,
      resolver: new _ResolutionAwareAssetResolver(
        bundle: config.bundle,
        devicePixelRatio: config.devicePixelRatio
      )
    );
  }

  void didUpdateConfig(AssetVendor oldConfig) {
    if (config.bundle != oldConfig.bundle ||
        config.devicePixelRatio != oldConfig.devicePixelRatio) {
      _bundle = new _ResolvingAssetBundle(
        bundle: config.bundle,
        resolver: new _ResolutionAwareAssetResolver(
          bundle: config.bundle,
          devicePixelRatio: config.devicePixelRatio
        )
      );
    }
  }

  Widget build(BuildContext context) {
    return new DefaultAssetBundle(bundle: _bundle, child: config.child);
  }
}
