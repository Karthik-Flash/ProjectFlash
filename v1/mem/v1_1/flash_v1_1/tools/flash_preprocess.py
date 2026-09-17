"""Project FLASH V1 -- DICOM -> uint8 model input.

This is the preprocessing contract. The FPGA is bit-exact from the uint8 tensor
onward, so this function is part of the model: the board runs this file unchanged.
"""
import warnings
import numpy as np
import cv2
import pydicom
from pydicom.pixels import apply_modality_lut, apply_voi_lut

# RSNA headers store PatientAge as '51' instead of DICOM's '051Y'; pydicom warns once per file.
warnings.filterwarnings('ignore', message='Invalid value for VR AS')

PREPROC_VERSION = 'flash-v1-preproc-1'


def _first(v):
    """WindowCenter/Width may be multi-valued; DICOM says use the first."""
    try:
        return float(v[0])
    except TypeError:
        return float(v)


def dicom_to_display(ds):
    """Stored pixels -> float64 image in [0, 255], as a radiologist would view it.
    Returns (image, info) where info records which path was taken."""
    arr = ds.pixel_array                                   # 1. decode
    if int(ds.get('NumberOfFrames', 1) or 1) > 1:
        arr = arr[0]
    if int(ds.get('SamplesPerPixel', 1)) != 1:
        raise ValueError('expected a greyscale radiograph (SamplesPerPixel=1)')

    photometric = str(ds.get('PhotometricInterpretation', 'MONOCHROME2')).strip()
    bits_stored = int(ds.get('BitsStored', 8))
    info = dict(photometric=photometric, bits_stored=bits_stored,
                rows=int(arr.shape[0]), cols=int(arr.shape[1]),
                transfer_syntax=str(ds.file_meta.TransferSyntaxUID.name) if 'TransferSyntaxUID' in ds.get('file_meta', {}) else '')

    x = apply_modality_lut(arr, ds).astype(np.float64)    # 2. modality LUT

    if 'VOILUTSequence' in ds and len(ds.VOILUTSequence) > 0:          # 3a. VOI LUT
        lut_bits = int(ds.VOILUTSequence[0].LUTDescriptor[2])
        y = apply_voi_lut(x, ds, index=0, prefer_lut=True).astype(np.float64)
        y = np.clip(y / float((1 << lut_bits) - 1), 0.0, 1.0) * 255.0
        info['voi'] = f'VOILUTSequence({lut_bits} bit)'
    elif 'WindowCenter' in ds and 'WindowWidth' in ds:                  # 3b. window
        c, w = _first(ds.WindowCenter), max(_first(ds.WindowWidth), 1.0)
        fn = str(ds.get('VOILUTFunction', 'LINEAR')).upper()
        if fn == 'SIGMOID':
            y = 255.0 / (1.0 + np.exp(-4.0 * (x - c) / w))
        elif fn == 'LINEAR_EXACT':
            y = np.clip((x - c) / w + 0.5, 0.0, 1.0) * 255.0
        else:   # LINEAR, PS3.3 C.11.2.1.2.1
            y = np.clip((x - (c - 0.5)) / max(w - 1.0, 1e-6) + 0.5, 0.0, 1.0) * 255.0
        info['voi'] = f'window C={c:g} W={w:g} {fn}'
    elif bits_stored <= 8:                                              # 3c. already display-ready
        y = np.clip(x, 0.0, 255.0)
        info['voi'] = 'none (8-bit)'
    else:                                                               # 3d. fallback, flagged
        lo, hi = np.percentile(x, [0.5, 99.5])
        y = np.clip((x - lo) / max(hi - lo, 1e-6), 0.0, 1.0) * 255.0
        info['voi'] = 'PERCENTILE-FALLBACK (no VOI tags)'

    if photometric == 'MONOCHROME1':                                    # 4. invert
        y = 255.0 - y
    return y, info


def letterbox_square(img):
    """5. Pad (not stretch) to a centred square with zeros."""
    h, w = img.shape
    s = max(h, w)
    out = np.zeros((s, s), dtype=img.dtype)
    top, left = (s - h) // 2, (s - w) // 2
    out[top:top + h, left:left + w] = img
    return out, top, left


def to_model_input(display, size):
    """6. Area-resize to size x size and round to uint8."""
    sq, _, _ = letterbox_square(display)
    r = cv2.resize(sq.astype(np.float32), (size, size), interpolation=cv2.INTER_AREA)
    return np.clip(np.rint(r), 0, 255).astype(np.uint8)


def preprocess_dataset(ds, sizes=(224,)):
    """Full pipeline on an opened dataset. Returns ({size: uint8 array}, info)."""
    display, info = dicom_to_display(ds)
    return {s: to_model_input(display, s) for s in sizes}, info


def preprocess_file(path, sizes=(224,)):
    return preprocess_dataset(pydicom.dcmread(path), sizes)


def preprocess_for_training(path, sizes=(28, 224)):
    """Used by the notebook's parallel pass: arrays + the header fields we analyse."""
    ds = pydicom.dcmread(path)
    arrays, info = preprocess_dataset(ds, sizes)
    info.update(patientId=str(ds.get('PatientID', '')), view=str(ds.get('ViewPosition', '')),
                sex=str(ds.get('PatientSex', '')), age=str(ds.get('PatientAge', '')),
                modality=str(ds.get('Modality', '')))
    return arrays, info
