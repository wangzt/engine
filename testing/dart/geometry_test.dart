// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math show sqrt;
import 'dart:math' show pi;
import 'dart:ui';

import 'package:test/test.dart';

void main() {
  test('OffsetBase.>=', () {
    expect(const Offset(0, 0), greaterThanOrEqualTo(const Offset(0, -1)));
    expect(const Offset(0, 0), greaterThanOrEqualTo(const Offset(-1, 0)));
    expect(const Offset(0, 0), greaterThanOrEqualTo(const Offset(-1, -1)));
    expect(const Offset(0, 0), greaterThanOrEqualTo(const Offset(0, 0)));
    expect(const Offset(0, 0), isNot(greaterThanOrEqualTo(const Offset(0, double.nan))));
    expect(const Offset(0, 0), isNot(greaterThanOrEqualTo(const Offset(double.nan, 0))));
    expect(const Offset(0, 0), isNot(greaterThanOrEqualTo(const Offset(10, -10))));
  });
  test('OffsetBase.<=', () {
    expect(const Offset(0, 0), lessThanOrEqualTo(const Offset(0, 1)));
    expect(const Offset(0, 0), lessThanOrEqualTo(const Offset(1, 0)));
    expect(const Offset(0, 0), lessThanOrEqualTo(const Offset(0, 0)));
    expect(const Offset(0, 0), isNot(lessThanOrEqualTo(const Offset(0, double.nan))));
    expect(const Offset(0, 0), isNot(lessThanOrEqualTo(const Offset(double.nan, 0))));
    expect(const Offset(0, 0), isNot(lessThanOrEqualTo(const Offset(10, -10))));
  });
  test('OffsetBase.>', () {
    expect(const Offset(0, 0), greaterThan(const Offset(-1, -1)));
    expect(const Offset(0, 0), isNot(greaterThan(const Offset(0, -1))));
    expect(const Offset(0, 0), isNot(greaterThan(const Offset(-1, 0))));
    expect(const Offset(0, 0), isNot(greaterThan(const Offset(double.nan, -1))));
  });
  test('OffsetBase.<', () {
    expect(const Offset(0, 0), lessThan(const Offset(1, 1)));
    expect(const Offset(0, 0), isNot(lessThan(const Offset(0, 1))));
    expect(const Offset(0, 0), isNot(lessThan(const Offset(1, 0))));
    expect(const Offset(0, 0), isNot(lessThan(const Offset(double.nan, 1))));
  });
  test('OffsetBase.==', () {
    expect(const Offset(0, 0), equals(const Offset(0, 0)));
    expect(const Offset(0, 0), isNot(equals(const Offset(1, 0))));
    expect(const Offset(0, 0), isNot(equals(const Offset(0, 1))));
  });
  test('Offset.direction', () {
    expect(const Offset(0.0, 0.0).direction, 0.0);
    expect(const Offset(0.0, 1.0).direction, pi / 2.0);
    expect(const Offset(0.0, -1.0).direction, -pi / 2.0);
    expect(const Offset(1.0, 0.0).direction, 0.0);
    expect(const Offset(1.0, 1.0).direction, pi / 4.0);
    expect(const Offset(1.0, -1.0).direction, -pi / 4.0);
    expect(const Offset(-1.0, 0.0).direction, pi);
    expect(const Offset(-1.0, 1.0).direction, pi * 3.0 / 4.0);
    expect(const Offset(-1.0, -1.0).direction, -pi * 3.0 / 4.0);
  });
  test('Offset.fromDirection', () {
    expect(Offset.fromDirection(0.0, 0.0), const Offset(0.0, 0.0));
    expect(Offset.fromDirection(pi / 2.0).dx, closeTo(0.0, 1e-12)); // aah, floating point math. i love you so.
    expect(Offset.fromDirection(pi / 2.0).dy, 1.0);
    expect(Offset.fromDirection(-pi / 2.0).dx, closeTo(0.0, 1e-12));
    expect(Offset.fromDirection(-pi / 2.0).dy, -1.0);
    expect(Offset.fromDirection(0.0), const Offset(1.0, 0.0));
    expect(Offset.fromDirection(pi / 4.0).dx, closeTo(1.0 / math.sqrt(2.0), 1e-12));
    expect(Offset.fromDirection(pi / 4.0).dy, closeTo(1.0 / math.sqrt(2.0), 1e-12));
    expect(Offset.fromDirection(-pi / 4.0).dx, closeTo(1.0 / math.sqrt(2.0), 1e-12));
    expect(Offset.fromDirection(-pi / 4.0).dy, closeTo(-1.0 / math.sqrt(2.0), 1e-12));
    expect(Offset.fromDirection(pi).dx, -1.0);
    expect(Offset.fromDirection(pi).dy, closeTo(0.0, 1e-12));
    expect(Offset.fromDirection(pi * 3.0 / 4.0).dx, closeTo(-1.0 / math.sqrt(2.0), 1e-12));
    expect(Offset.fromDirection(pi * 3.0 / 4.0).dy, closeTo(1.0 / math.sqrt(2.0), 1e-12));
    expect(Offset.fromDirection(-pi * 3.0 / 4.0).dx, closeTo(-1.0 / math.sqrt(2.0), 1e-12));
    expect(Offset.fromDirection(-pi * 3.0 / 4.0).dy, closeTo(-1.0 / math.sqrt(2.0), 1e-12));
    expect(Offset.fromDirection(0.0, 2.0), const Offset(2.0, 0.0));
    expect(Offset.fromDirection(pi / 6, 2.0).dx, closeTo(math.sqrt(3.0), 1e-12));
    expect(Offset.fromDirection(pi / 6, 2.0).dy, closeTo(1.0, 1e-12));
  });
  test('Size.aspectRatio', () {
    expect(const Size(0.0, 0.0).aspectRatio, 0.0);
    expect(const Size(-0.0, 0.0).aspectRatio, 0.0);
    expect(const Size(0.0, -0.0).aspectRatio, 0.0);
    expect(const Size(-0.0, -0.0).aspectRatio, 0.0);
    expect(const Size(0.0, 1.0).aspectRatio, 0.0);
    expect(const Size(0.0, -1.0).aspectRatio, -0.0);
    expect(const Size(1.0, 0.0).aspectRatio, double.infinity);
    expect(const Size(1.0, 1.0).aspectRatio, 1.0);
    expect(const Size(1.0, -1.0).aspectRatio, -1.0);
    expect(const Size(-1.0, 0.0).aspectRatio, -double.infinity);
    expect(const Size(-1.0, 1.0).aspectRatio, -1.0);
    expect(const Size(-1.0, -1.0).aspectRatio, 1.0);
    expect(const Size(3.0, 4.0).aspectRatio, 3.0 / 4.0);
  });
  test('Rect.fromCenter', () {
    Rect rect = Rect.fromCenter(center: const Offset(1.0, 3.0), width: 5.0, height: 7.0);
    expect(rect.left, -1.5);
    expect(rect.top, -0.5);
    expect(rect.right, 3.5);
    expect(rect.bottom, 6.5);
    rect = Rect.fromCenter(center: const Offset(0.0, 0.0), width: 0.0, height: 0.0);
    expect(rect.left, 0.0);
    expect(rect.top, 0.0);
    expect(rect.right, 0.0);
    expect(rect.bottom, 0.0);
    rect = Rect.fromCenter(center: const Offset(double.nan, 0.0), width: 0.0, height: 0.0);
    expect(rect.left, isNaN);
    expect(rect.top, 0.0);
    expect(rect.right, isNaN);
    expect(rect.bottom, 0.0);
    rect = Rect.fromCenter(center: const Offset(0.0, double.nan), width: 0.0, height: 0.0);
    expect(rect.left, 0.0);
    expect(rect.top, isNaN);
    expect(rect.right, 0.0);
    expect(rect.bottom, isNaN);
  });
}
