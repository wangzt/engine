// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

part of engine;

/// Mixin used by surfaces that clip their contents using an overflowing DOM
/// element.
mixin _DomClip on PersistedContainerSurface {
  /// The dedicated child container element that's separate from the
  /// [rootElement] is used to compensate for the coordinate system shift
  /// introduced by the [rootElement] translation.
  @override
  html.Element get childContainer => _childContainer;
  html.Element _childContainer;

  @override
  void adoptElements(_DomClip oldSurface) {
    super.adoptElements(oldSurface);
    _childContainer = oldSurface._childContainer;
    oldSurface._childContainer = null;
  }

  @override
  html.Element createElement() {
    final html.Element element = defaultCreateElement('flt-clip');
    if (!debugShowClipLayers) {
      // Hide overflow in production mode. When debugging we want to see the
      // clipped picture in full.
      element.style.overflow = 'hidden';
    } else {
      // Display the outline of the clipping region. When debugShowClipLayers is
      // `true` we don't hide clip overflow (see above). This outline helps
      // visualizing clip areas.
      element.style.boxShadow = 'inset 0 0 10px green';
    }
    _childContainer = html.Element.tag('flt-clip-interior');
    if (_debugExplainSurfaceStats) {
      // This creates an additional interior element. Count it too.
      _surfaceStatsFor(this).allocatedDomNodeCount++;
    }
    _childContainer.style.position = 'absolute';
    element.append(_childContainer);
    return element;
  }

  @override
  void recycle() {
    super.recycle();

    // Do not detach the child container from the root. It is permanently
    // attached. The elements are reused together and are detached from the DOM
    // together.
    _childContainer = null;
  }
}

/// A surface that creates a rectangular clip.
class PersistedClipRect extends PersistedContainerSurface with _DomClip {
  PersistedClipRect(Object paintedBy, this.rect) : super(paintedBy);

  final ui.Rect rect;

  @override
  void recomputeTransformAndClip() {
    _transform = parent._transform;
    _globalClip = parent._globalClip.intersect(localClipRectToGlobalClip(
      localClip: rect,
      transform: _transform,
    ));
  }

  @override
  html.Element createElement() {
    return super.createElement()..setAttribute('clip-type', 'rect');
  }

  @override
  void apply() {
    rootElement.style
      ..transform = 'translate(${rect.left}px, ${rect.top}px)'
      ..width = '${rect.right - rect.left}px'
      ..height = '${rect.bottom - rect.top}px';

    // Translate the child container in the opposite direction to compensate for
    // the shift in the coordinate system introduced by the translation of the
    // rootElement. Clipping in Flutter has no effect on the coordinate system.
    childContainer.style.transform =
        'translate(${-rect.left}px, ${-rect.top}px)';
  }

  @override
  void update(PersistedClipRect oldSurface) {
    super.update(oldSurface);
    if (rect != oldSurface.rect) {
      apply();
    }
  }
}

/// A surface that creates a rounded rectangular clip.
class PersistedClipRRect extends PersistedContainerSurface with _DomClip {
  PersistedClipRRect(Object paintedBy, this.rrect, this.clipBehavior)
      : super(paintedBy);

  final ui.RRect rrect;
  // TODO(yjbanov): can this be controlled in the browser?
  final ui.Clip clipBehavior;

  @override
  void recomputeTransformAndClip() {
    _transform = parent._transform;
    _globalClip = parent._globalClip.intersect(localClipRectToGlobalClip(
      localClip: rrect.outerRect,
      transform: _transform,
    ));
  }

  @override
  html.Element createElement() {
    return super.createElement()..setAttribute('clip-type', 'rrect');
  }

  @override
  void apply() {
    rootElement.style
      ..transform = 'translate(${rrect.left}px, ${rrect.top}px)'
      ..width = '${rrect.width}px'
      ..height = '${rrect.height}px'
      ..borderTopLeftRadius = '${rrect.tlRadiusX}px'
      ..borderTopRightRadius = '${rrect.trRadiusX}px'
      ..borderBottomRightRadius = '${rrect.brRadiusX}px'
      ..borderBottomLeftRadius = '${rrect.blRadiusX}px';

    // Translate the child container in the opposite direction to compensate for
    // the shift in the coordinate system introduced by the translation of the
    // rootElement. Clipping in Flutter has no effect on the coordinate system.
    childContainer.style.transform =
        'translate(${-rrect.left}px, ${-rrect.top}px)';
  }

  @override
  void update(PersistedClipRRect oldSurface) {
    super.update(oldSurface);
    if (rrect != oldSurface.rrect) {
      apply();
    }
  }
}

class PersistedPhysicalShape extends PersistedContainerSurface with _DomClip {
  PersistedPhysicalShape(Object paintedBy, this.path, this.elevation, int color,
      int shadowColor, this.clipBehavior)
      : this.color = ui.Color(color),
        this.shadowColor = ui.Color(shadowColor),
        super(paintedBy);

  final ui.Path path;
  final double elevation;
  final ui.Color color;
  final ui.Color shadowColor;
  final ui.Clip clipBehavior;
  html.Element _clipElement;

  @override
  void recomputeTransformAndClip() {
    _transform = parent._transform;

    final ui.RRect roundRect = path.webOnlyPathAsRoundedRect;
    if (roundRect != null) {
      _globalClip = parent._globalClip.intersect(localClipRectToGlobalClip(
        localClip: roundRect.outerRect,
        transform: transform,
      ));
    } else {
      ui.Rect rect = path.webOnlyPathAsRect;
      if (rect != null) {
        _globalClip = parent._globalClip.intersect(localClipRectToGlobalClip(
          localClip: rect,
          transform: transform,
        ));
      } else {
        _globalClip = parent._globalClip;
      }
    }
  }

  void _applyColor() {
    rootElement.style.backgroundColor = color.toCssString();
  }

  void _applyShadow() {
    ElevationShadow.applyShadow(rootElement.style, elevation, shadowColor);
  }

  @override
  html.Element createElement() {
    return super.createElement()..setAttribute('clip-type', 'physical-shape');
  }

  @override
  void apply() {
    _applyColor();
    _applyShadow();
    _applyShape();
  }

  void _applyShape() {
    if (path == null) return;
    // Handle special case of round rect physical shape mapping to
    // rounded div.
    final ui.RRect roundRect = path.webOnlyPathAsRoundedRect;
    if (roundRect != null) {
      final borderRadius = '${roundRect.tlRadiusX}px ${roundRect.trRadiusX}px '
          '${roundRect.brRadiusX}px ${roundRect.blRadiusX}px';
      var style = rootElement.style;
      style
        ..transform = 'translate(${roundRect.left}px, ${roundRect.top}px)'
        ..width = '${roundRect.width}px'
        ..height = '${roundRect.height}px'
        ..borderRadius = borderRadius;
      childContainer.style.transform =
          'translate(${-roundRect.left}px, ${-roundRect.top}px)';
      if (clipBehavior != ui.Clip.none) {
        style.overflow = 'hidden';
      }
      return;
    } else {
      ui.Rect rect = path.webOnlyPathAsRect;
      if (rect != null) {
        final style = rootElement.style;
        style
          ..transform = 'translate(${rect.left}px, ${rect.top}px)'
          ..width = '${rect.width}px'
          ..height = '${rect.height}px'
          ..borderRadius = '';
        childContainer.style.transform =
            'translate(${-rect.left}px, ${-rect.top}px)';
        if (clipBehavior != ui.Clip.none) {
          style.overflow = 'hidden';
        }
        return;
      } else {
        Ellipse ellipse = path.webOnlyPathAsCircle;
        if (ellipse != null) {
          final double rx = ellipse.radiusX;
          final double ry = ellipse.radiusY;
          final borderRadius = rx == ry ? '${rx}px ' : '${rx}px ${ry}px ';
          var style = rootElement.style;
          final double left = ellipse.x - rx;
          final double top = ellipse.y - ry;
          style
            ..transform = 'translate(${left}px, ${top}px)'
            ..width = '${rx * 2}px'
            ..height = '${ry * 2}px'
            ..borderRadius = borderRadius;
          childContainer.style.transform = 'translate(${-left}px, ${-top}px)';
          if (clipBehavior != ui.Clip.none) {
            style.overflow = 'hidden';
          }
          return;
        }
      }
    }

    ui.Rect bounds = path.getBounds();
    String svgClipPath =
        _pathToSvgClipPath(path, offsetX: -bounds.left, offsetY: -bounds.top);
    assert(_clipElement == null);
    _clipElement =
        html.Element.html(svgClipPath, treeSanitizer: _NullTreeSanitizer());
    domRenderer.append(rootElement, _clipElement);
    domRenderer.setElementStyle(
        rootElement, 'clip-path', 'url(#svgClip${_clipIdCounter})');
    domRenderer.setElementStyle(
        rootElement, '-webkit-clip-path', 'url(#svgClip${_clipIdCounter})');
    final html.CssStyleDeclaration rootElementStyle = rootElement.style;
    rootElementStyle
      ..overflow = ''
      ..transform = 'translate(${bounds.left}px, ${bounds.top}px)'
      ..width = '${bounds.width}px'
      ..height = '${bounds.height}px'
      ..borderRadius = '';
    childContainer.style.transform =
        'translate(${-bounds.left}px, ${-bounds.top}px)';
  }

  @override
  void update(PersistedPhysicalShape oldSurface) {
    super.update(oldSurface);
    if (oldSurface.color != color) {
      _applyColor();
    }
    if (oldSurface.elevation != elevation ||
        oldSurface.shadowColor != shadowColor) {
      _applyShadow();
    }
    if (oldSurface.path != path) {
      oldSurface._clipElement?.remove();
      // Reset style on prior element since we may have switched between
      // rect/rrect and arbitrary path.
      var style = rootElement.style;
      style.transform = '';
      style.borderRadius = '';
      domRenderer.setElementStyle(rootElement, 'clip-path', '');
      domRenderer.setElementStyle(rootElement, '-webkit-clip-path', '');
      _applyShape();
    } else {
      _clipElement = oldSurface._clipElement;
    }
    oldSurface._clipElement = null;
  }
}

/// A surface that clips it's children.
class PersistedClipPath extends PersistedContainerSurface {
  PersistedClipPath(Object paintedBy, this.clipPath, this.clipBehavior)
      : super(paintedBy);

  final ui.Path clipPath;
  final ui.Clip clipBehavior;
  html.Element _clipElement;

  @override
  html.Element createElement() {
    return defaultCreateElement('flt-clippath');
  }

  @override
  void apply() {
    if (clipPath == null) {
      if (_clipElement != null) {
        domRenderer.setElementStyle(childContainer, 'clip-path', '');
        domRenderer.setElementStyle(childContainer, '-webkit-clip-path', '');
        _clipElement.remove();
        _clipElement = null;
      }
      return;
    }
    String svgClipPath = _pathToSvgClipPath(clipPath);
    _clipElement?.remove();
    _clipElement =
        html.Element.html(svgClipPath, treeSanitizer: _NullTreeSanitizer());
    domRenderer.append(childContainer, _clipElement);
    domRenderer.setElementStyle(
        childContainer, 'clip-path', 'url(#svgClip${_clipIdCounter})');
    domRenderer.setElementStyle(
        childContainer, '-webkit-clip-path', 'url(#svgClip${_clipIdCounter})');
  }

  @override
  void update(PersistedClipPath oldSurface) {
    super.update(oldSurface);
    if (oldSurface.clipPath != clipPath) {
      oldSurface._clipElement?.remove();
      apply();
    } else {
      _clipElement = oldSurface._clipElement;
    }
    oldSurface._clipElement = null;
  }

  @override
  void recycle() {
    _clipElement?.remove();
    _clipElement = null;
    super.recycle();
  }
}
