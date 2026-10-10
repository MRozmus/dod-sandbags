#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 dod-modding contributors
"""Bake the installed DoD bag into a static, centered GoldSrc model.

No game data is tracked. Texture/mesh data comes from the server's stock asset.
The resulting mesh bounds, StudioMDL hitbox and network BBOX are 64 x 32 x 16.
Layout: Valve HLSDK engine/studio.h, StudioMDL v10 (little endian).
"""
import argparse
import math
from pathlib import Path
import struct

BOUNDS_MIN = (-32.0, -16.0, -8.0)
BOUNDS_MAX = (32.0, 16.0, 8.0)


def unpack(data, fmt, offset):
    return struct.unpack_from('<' + fmt, data, offset)


def rotate(vector, angles):
    x, y, z = vector
    rx, ry, rz = angles
    y, z = y * math.cos(rx) - z * math.sin(rx), y * math.sin(rx) + z * math.cos(rx)
    x, z = x * math.cos(ry) + z * math.sin(ry), -x * math.sin(ry) + z * math.cos(ry)
    x, y = x * math.cos(rz) - y * math.sin(rz), x * math.sin(rz) + y * math.cos(rz)
    return (x, y, z)


def generate(source: Path, destination: Path):
    original = source.read_bytes()
    data = bytearray(original)
    if data[:4] != b'IDST' or unpack(data, 'i', 4)[0] != 10:
        raise ValueError('Expected GoldSrc StudioMDL v10')
    if unpack(data, 'i', 72)[0] != len(data):
        raise ValueError('Unexpected model length')
    if tuple(unpack(data, 'i', offset)[0] for offset in (140, 148, 156, 164, 172, 204)) != (1, 0, 1, 1, 1, 1):
        raise ValueError('Expected one bone/hitbox/sequence/bodypart, no controllers')
    if unpack(data, 'i', 180)[0] < 1:
        raise ValueError('Expected embedded textures for automatic client download')
    bone = unpack(data, 'i', 144)[0]
    hitbox = unpack(data, 'i', 160)[0]
    sequence = unpack(data, 'i', 168)[0]
    bodypart = unpack(data, 'i', 208)[0]
    if unpack(data, 'i', bone + 32)[0] != -1 or unpack(data, 'i', bodypart + 64)[0] != 1:
        raise ValueError('Expected a single root bone and single body model')
    model = unpack(data, 'i', bodypart + 72)[0]
    vertex_count, vertex_bones, vertices = unpack(data, '3i', model + 80)
    normal_count, normal_bones, normals = unpack(data, '3i', model + 92)
    if any(data[vertex_bones:vertex_bones + vertex_count]) or any(data[normal_bones:normal_bones + normal_count]):
        raise ValueError('Unexpected bone assignments')
    animation = unpack(data, 'i', sequence + 124)[0]
    values = list(unpack(data, '6f', bone + 64))
    scales = unpack(data, '6f', bone + 88)
    # Each nonzero channel has an RLE header followed by the first frame's value.
    for channel, offset in enumerate(unpack(data, '6H', animation)):
        if offset:
            if not data[animation + offset]:
                raise ValueError('Missing first animation sample')
            values[channel] += unpack(data, 'h', animation + offset + 2)[0] * scales[channel]
    pose = []
    for index in range(vertex_count):
        point = rotate(unpack(data, '3f', vertices + index * 12), values[3:])
        pose.append(tuple(point[axis] + values[axis] for axis in range(3)))
    # The stock bag's visible footprint is diagonal even after baking its bone.
    # Align its longest bottom-rim edge with X before fitting the shared BBOX.
    # This rotates coordinates/normals only; mesh streams and UVs stay intact.
    floor_z = min(point[2] for point in pose)
    rim = [point for point in pose if abs(point[2] - floor_z) < 0.001]
    if len(rim) != 4:
        raise ValueError('Expected a four-corner bottom rim for axis alignment')
    rim_x = sum(point[0] for point in rim) / 4
    rim_y = sum(point[1] for point in rim) / 4
    rim.sort(key=lambda point: math.atan2(point[1] - rim_y, point[0] - rim_x))
    edges = [(rim[(index + 1) % 4][0] - point[0],
              rim[(index + 1) % 4][1] - point[1]) for index, point in enumerate(rim)]
    edge = max(edges, key=lambda vector: vector[0] ** 2 + vector[1] ** 2)
    alignment = -math.atan2(edge[1], edge[0])
    pose = [rotate(point, (0.0, 0.0, alignment)) for point in pose]
    minimum = tuple(min(point[axis] for point in pose) for axis in range(3))
    maximum = tuple(max(point[axis] for point in pose) for axis in range(3))
    if any(maximum[axis] - minimum[axis] <= 0 for axis in range(3)):
        raise ValueError('Degenerate source mesh')
    center = tuple((minimum[axis] + maximum[axis]) / 2 for axis in range(3))
    stretch = tuple((BOUNDS_MAX[axis] - BOUNDS_MIN[axis]) / (maximum[axis] - minimum[axis]) for axis in range(3))
    for index, point in enumerate(pose):
        result = tuple((point[axis] - center[axis]) * stretch[axis] for axis in range(3))
        struct.pack_into('<3f', data, vertices + index * 12, *result)
    for index in range(normal_count):
        normal = rotate(unpack(data, '3f', normals + index * 12), values[3:])
        normal = rotate(normal, (0.0, 0.0, alignment))
        normal = tuple(normal[axis] / stretch[axis] for axis in range(3))
        length = math.sqrt(sum(value * value for value in normal))
        if length == 0:
            raise ValueError('Degenerate source normal')
        struct.pack_into('<3f', data, normals + index * 12, *(value / length for value in normal))
    # Freeze the baked pose. Unreferenced original animation bytes can stay;
    # no offset changes are needed, preserving the embedded texture/UV layout.
    struct.pack_into('<12f', data, bone + 64, *([0.0] * 12))
    struct.pack_into('<6H', data, animation, *([0] * 6))
    struct.pack_into('<f', data, sequence + 32, 1.0)
    struct.pack_into('<i', data, sequence + 56, 1)
    struct.pack_into('<2i3f2i', data, sequence + 68, 0, 0, 0.0, 0.0, 0.0, 0, 0)
    struct.pack_into('<6f', data, sequence + 96, *BOUNDS_MIN, *BOUNDS_MAX)
    struct.pack_into('<ii6f', data, hitbox, 0, 0, *BOUNDS_MIN, *BOUNDS_MAX)
    for offset in (88, 112):
        struct.pack_into('<6f', data, offset, *BOUNDS_MIN, *BOUNDS_MAX)
    struct.pack_into('<f', data, model + 68, math.sqrt(sum(value * value for value in BOUNDS_MAX)))
    name = b'models/dod_modding/sandbag_v6.mdl'
    data[8:72] = name.ljust(64, b'\0')
    # Read back serialized mesh vertices: verify the output, not just the math.
    result = [unpack(data, '3f', vertices + index * 12) for index in range(vertex_count)]
    for axis in range(3):
        if abs(min(point[axis] for point in result) - BOUNDS_MIN[axis]) > 0.0001 or abs(max(point[axis] for point in result) - BOUNDS_MAX[axis]) > 0.0001:
            raise ValueError('Mesh and hull bounds differ')
    if unpack(data, '6f', hitbox + 8) != BOUNDS_MIN + BOUNDS_MAX:
        raise ValueError('Serialized hitbox differs from hull')
    # Regression guard: the client renderer depends on the stock mesh layout.
    # Never move geometry streams or append normals/triangles to this MDL.
    if len(data) != len(original):
        raise ValueError('Source model layout/length changed')
    mutable = [(8, 72), (88, 136), (bone + 64, bone + 112),
               (animation, animation + 12), (sequence + 32, sequence + 36),
               (sequence + 56, sequence + 60), (sequence + 68, sequence + 96),
               (sequence + 96, sequence + 120), (hitbox, hitbox + 32),
               (model + 68, model + 72), (vertices, vertices + vertex_count * 12),
               (normals, normals + normal_count * 12)]
    allowed = bytearray(len(data))
    for begin, end in mutable:
        allowed[begin:end] = b'\1' * (end - begin)
    if any(before != after and not allowed[index]
           for index, (before, after) in enumerate(zip(original, data))):
        raise ValueError('Unexpected mesh/texture layout modification')
    output_floor = min(point[2] for point in result)
    output_rim = [point for point in result if abs(point[2] - output_floor) < 0.001]
    rx = sum(point[0] for point in output_rim) / 4
    ry = sum(point[1] for point in output_rim) / 4
    output_rim.sort(key=lambda point: math.atan2(point[1] - ry, point[0] - rx))
    output_edges = []
    for index, point in enumerate(output_rim):
        other = output_rim[(index + 1) % 4]
        dx, dy = abs(other[0] - point[0]), abs(other[1] - point[1])
        output_edges.append((dx, dy))
        # The stock bottom rim is slightly tapered, rather than rectangular.
        if min(dx, dy) > max(dx, dy) * 0.2:
            raise ValueError('Visible bag edge is not aligned with adjacent-placement grid')
    if not any(dx > 10.0 and dy < 0.01 for dx, dy in output_edges):
        raise ValueError('Reference bag edge is not parallel to placement X axis')
    destination.write_bytes(data)
    print(f'Sandbag model: static mesh/hitbox/hull 64 x 32 x 16, {len(data)} bytes; visible edges aligned with placement axes, original topology/UV preserved')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    generate(args.source, args.destination)
