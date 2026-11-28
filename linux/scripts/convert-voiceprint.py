#!/usr/bin/env python3
import hashlib
import struct
import sys

SHA256 = "7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068"


def varint(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        if c < 0x80:
            return r, i
        s += 7


def fields(b):
    i, n = 0, len(b)
    while i < n:
        key, i = varint(b, i)
        f, w = key >> 3, key & 7
        if w == 0:
            v, i = varint(b, i)
        elif w == 1:
            v, i = b[i:i + 8], i + 8
        elif w == 2:
            ln, i = varint(b, i)
            v, i = b[i:i + ln], i + ln
        elif w == 5:
            v, i = b[i:i + 4], i + 4
        else:
            raise ValueError("wire type %d" % w)
        yield f, w, v


def ints(w, v):
    if w != 2:
        return [v if v < 1 << 63 else v - (1 << 64)]
    out, i = [], 0
    while i < len(v):
        x, i = varint(v, i)
        out.append(x if x < 1 << 63 else x - (1 << 64))
    return out


def tensor(b):
    t = {"dims": [], "raw": None, "float": []}
    for f, w, v in fields(b):
        if f == 1:
            t["dims"] += ints(w, v)
        elif f == 8:
            t["name"] = v.decode()
        elif f == 9:
            t["raw"] = v
        elif f == 4:
            t["float"] += list(struct.unpack("<%df" % (len(v) // 4), v)) if w == 2 else [struct.unpack("<f", v)[0]]
    return t


def floats(t):
    return list(struct.unpack("<%df" % (len(t["raw"]) // 4), t["raw"])) if t["raw"] is not None else t["float"]


def node(b):
    n = {"in": [], "out": [], "attrs": {}}
    for f, w, v in fields(b):
        if f == 1:
            n["in"].append(v.decode())
        elif f == 2:
            n["out"].append(v.decode())
        elif f == 4:
            n["op"] = v.decode()
        elif f == 5:
            a = {"ints": []}
            for g, x, y in fields(v):
                if g == 1:
                    a["name"] = y.decode()
                elif g == 3:
                    a["i"] = ints(x, y)[0]
                elif g == 8:
                    a["ints"] += ints(x, y)
            n["attrs"][a["name"]] = a
    return n


def load(path):
    data = open(path, "rb").read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        sys.exit("not the pinned voxceleb_resnet34_LM.onnx")
    graph = next(v for f, _w, v in fields(data) if f == 7)
    nodes, inits = [], {}
    for f, _w, v in fields(graph):
        if f == 1:
            nodes.append(node(v))
        elif f == 5:
            t = tensor(v)
            inits[t["name"]] = t
    return nodes, inits


def f16(values) -> bytes:
    return struct.pack("<%de" % len(values), *values)


def main(src, out):
    nodes, inits = load(src)
    slots = {}

    def slot(name):
        return slots.setdefault(name, len(slots))

    start = next(n for n in nodes if n["op"] == "Unsqueeze")["out"][0]
    slot(start)
    produced = {start}
    ops = []
    for n in nodes:
        op = n["op"]
        if op == "Conv" and n["in"][0] in produced:
            w, b = inits[n["in"][1]], inits[n["in"][2]]
            cout, cin, kh, kw = w["dims"]
            stride = n["attrs"]["strides"]["ints"]
            pads = n["attrs"]["pads"]["ints"]
            assert kh == kw and stride[0] == stride[1] and n["attrs"]["group"]["i"] == 1, n
            assert (kh == 3 and pads == [1, 1, 1, 1]) or (kh == 1 and pads == [0, 0, 0, 0] and stride[0] == 2), (kh, pads, stride)
            ops.append({"op": "conv", "src": n["in"][0], "dst": n["out"][0], "cin": cin, "cout": cout, "k": kh,
                        "stride": stride[0], "relu": 0, "w": floats(w), "b": floats(b)})
            produced.add(n["out"][0])
        elif op == "Add" and all(x in produced for x in n["in"]):
            ops.append({"op": "add", "a": n["in"][0], "b": n["in"][1], "dst": n["out"][0], "relu": 0})
            produced.add(n["out"][0])
        elif op == "Relu" and n["in"][0] in produced:
            assert ops[-1]["dst"] == n["in"][0], "relu not right after its op"
            ops[-1]["relu"] = 1
            ops[-1]["dst"] = n["out"][0]
            produced.add(n["out"][0])
    blob = bytearray(b"CVP1")
    blob += struct.pack("<I", len(ops))
    for o in ops:
        if o["op"] == "conv":
            blob += struct.pack("<8I", 1, slot(o["src"]), slot(o["dst"]), o["cin"], o["cout"], o["k"], o["stride"], o["relu"])
            blob += f16(o["w"]) + struct.pack("<%df" % o["cout"], *o["b"])
        else:
            blob += struct.pack("<5I", 2, slot(o["a"]), slot(o["b"]), slot(o["dst"]), o["relu"])
    trunk_end = ops[-1]["dst"]
    assert trunk_end == "343", trunk_end
    fc, bias, mean = inits["model.seg_1.weight"], inits["model.seg_1.bias"], inits["mean_vec"]
    dims, flat = fc["dims"]
    blob += struct.pack("<3I", 256, flat // 512, dims)
    blob += f16(floats(fc)) + struct.pack("<%df" % dims, *floats(bias)) + struct.pack("<%df" % dims, *floats(mean))
    open(out, "wb").write(blob)
    print("%d ops, %d slots, %.1f MB" % (len(ops), len(slots), len(blob) / 1e6))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
