#!/usr/bin/env python3
"""让 `carousel/photo` 下发缩放过的预览图，而不是原图。

## 为什么要这个补丁

手机端 `/api/v1/devices/{id}/carousel/photo` 原本直接 `FileResponse` 送原图。
照片后端是 **JuiceFS → 七牛**（`immich-qiniu.service`，桶 `bloom-ink`），每张都要
跨网络取，**耗时与体积近似成正比**：

    item 4421   2.47 MB  ->  7.7 s
    item 4422   0.25 MB  ->  1.4 s
    item 4423   1.98 MB  ->  6.3 s

客户端单次下载时限是 **25 秒**（`photo_store.dart` 的 `downloadLeash`，不是
`bloom_api_client.dart` 里那个 60 秒）。原图在移动网络下会撞线，表现为

    [BloomCarousel] photo unavailable item=4812 reason=timeout

**两端一致**，因为那是共享 Dart 代码——所以修在服务端，两端同时受益，不用动
任何客户端。

## 补丁做了什么

1. 新增 `_carousel_phone_photo(original)`：用 Pillow 把原图缩到最大边
   `CAROUSEL_PHONE_MAX_SIDE`（默认 1400），带 `exif_transpose` 方向校正，
   结果缓存到 `<FRAME_RENDER_CACHE_DIR>/phone-photo/`。缓存按
   `路径 + mtime_ns + size + 目标边长` 做键，原图变了会自动重算。
2. `carousel/photo` 改为下发它，etag 也随之基于缩放后的文件。
3. **任何异常都回退到原图**——绝不因为预览生成失败而让照片取不到。

## 实测效果

    改前           改后(首次)        改后(缓存命中)
    2.47MB / 7.7s  0.45MB / 2.8s    0.45MB / 0.91s
    1.98MB / 6.3s  0.37MB / 4.1s    0.37MB / 1.70s

## 怎么用

`main.py` 是**打进镜像的，不是挂载的**，所以这个改动不会随 git 走。改完要么
重建镜像，要么按下面这样灌进运行中的容器：

    scp tools/server/phone_photo_preview.py <host>:/tmp/
    ssh <host> 'docker cp /tmp/phone_photo_preview.py immich_frame_service:/tmp/ \
      && docker exec immich_frame_service python /tmp/phone_photo_preview.py \
      && docker restart immich_frame_service'

脚本是**幂等**的：已经打过就跳过，不会重复插入。它会先把原文件备份到
`/app/app/main.py.bak-phone-preview`。

## 注意

**重建镜像会丢掉这个补丁。** 它是打在容器文件系统里的，宿主机的 git 仓库
管不到。仓库里保留这份脚本，就是为了重建之后能一条命令重新打上。
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import shutil
import sys

HELPER_MARKER = "_carousel_phone_photo"

HELPER = '''

CAROUSEL_PHONE_MAX_SIDE = int(os.environ.get("CAROUSEL_PHONE_MAX_SIDE", "1400"))


def _carousel_phone_photo(original: Path) -> Path:
    """把原图缩到手机需要的尺寸并缓存，返回应当下发的文件。

    手机 `/carousel/photo` 此前直接发原图（实测 2880x2160 / 2.4MB）。照片后端是
    JuiceFS → 七牛，每张都要跨网络取，耗时与体积近似成正比（实测 2.4MB → 7.7s、
    0.25MB → 1.4s）。客户端单次下载时限 25 秒，原图在移动网络下会撞线，表现为
    `photo unavailable reason=timeout`——两端一致，因为那是共享 Dart 代码。

    缩放失败时**回退到原图**，绝不因为预览生成失败而让照片取不到。
    """
    try:
        from PIL import Image, ImageOps
    except Exception:
        return original
    try:
        cache_dir = Path(settings.frame_render_cache_dir) / "phone-photo"
        cache_dir.mkdir(parents=True, exist_ok=True)
        st = original.stat()
        key = hashlib.sha256(
            f"{original}:{st.st_mtime_ns}:{st.st_size}:{CAROUSEL_PHONE_MAX_SIDE}".encode()
        ).hexdigest()
        out = cache_dir / f"{key}.jpg"
        if out.exists() and out.stat().st_size > 0:
            return out
        with Image.open(original) as im:
            im = ImageOps.exif_transpose(im)
            if im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            if max(im.size) > CAROUSEL_PHONE_MAX_SIDE:
                im.thumbnail(
                    (CAROUSEL_PHONE_MAX_SIDE, CAROUSEL_PHONE_MAX_SIDE), Image.LANCZOS
                )
            tmp = out.with_suffix(".tmp")
            im.save(tmp, "JPEG", quality=88, optimize=True)
            tmp.replace(out)
        return out
    except Exception:
        logger.exception("phone preview failed, serving original: %s", original)
        return original

'''

ENDPOINT_ANCHOR = '@app.post("/api/v1/devices/{device_id}/carousel/photo")'

OLD_BODY = """    path = media_path(str(detail["original_path"]))
    etag = hashlib.sha256(
        f"carousel:{payload.item_id}:{detail['asset_id']}:{path.stat().st_mtime_ns}".encode()
    ).hexdigest()"""

NEW_BODY = """    path = media_path(str(detail["original_path"]))
    # 下发缩放过的预览图，而不是原图。
    served = _carousel_phone_photo(path)
    etag = hashlib.sha256(
        f"carousel:{payload.item_id}:{detail['asset_id']}:{served.stat().st_mtime_ns}".encode()
    ).hexdigest()"""

OLD_RETURN = """    return FileResponse(
        path,
        media_type=mimetypes.guess_type(path.name)[0] or "application/octet-stream",
        headers={"ETag": f'"{etag}"', "Cache-Control": "private, no-cache"},
    )"""

NEW_RETURN = """    return FileResponse(
        served,
        media_type="image/jpeg",
        headers={"ETag": f'"{etag}"', "Cache-Control": "private, no-cache"},
    )"""


def patch_source(src: str) -> tuple[str, str]:
    """返回 (打补丁后的源码, 说明)。已打过则原样返回并说明。"""
    if HELPER_MARKER in src:
        return src, "已经打过补丁，跳过"

    if ENDPOINT_ANCHOR not in src:
        raise SystemExit(f"找不到锚点：{ENDPOINT_ANCHOR}")
    src = src.replace(ENDPOINT_ANCHOR, HELPER.lstrip("\n") + ENDPOINT_ANCHOR, 1)

    for old, new, label in (
        (OLD_BODY, NEW_BODY, "photo 接口的取图段"),
        (OLD_RETURN, NEW_RETURN, "photo 接口的返回段"),
    ):
        if old not in src:
            raise SystemExit(f"找不到锚点：{label}")
        src = src.replace(old, new, 1)

    return src, "补丁已应用"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--path",
        default="/app/app/main.py",
        help="main.py 的位置（默认容器内的 /app/app/main.py）",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="只打印会改什么，不落盘",
    )
    args = ap.parse_args()

    target = pathlib.Path(args.path)
    if not target.exists():
        raise SystemExit(f"找不到 {target}")

    src = target.read_text(encoding="utf-8")
    patched, note = patch_source(src)

    if patched == src:
        print(note)
        return 0

    if args.dry_run:
        print(f"{note}（dry-run，未落盘）")
        print(f"  源码 {len(src)} -> {len(patched)} 字符 "
              f"(+{len(patched) - len(src)})")
        return 0

    backup = target.with_name(target.name + ".bak-phone-preview")
    shutil.copy2(target, backup)
    target.write_text(patched, encoding="utf-8")

    digest = hashlib.sha256(patched.encode("utf-8")).hexdigest()[:12]
    print(f"{note}")
    print(f"  备份 {backup}")
    print(f"  {target}   sha256(前12位)={digest}")
    print("  记得重启：docker restart immich_frame_service")
    return 0


if __name__ == "__main__":
    sys.exit(main())
