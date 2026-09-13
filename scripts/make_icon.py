"""Package already-generated PNG renditions into the standard ICNS container."""
from pathlib import Path
import struct
import subprocess
root = Path(__file__).resolve().parents[1]
folder = root / 'assets/AppIcon.iconset'
folder.mkdir(exist_ok=True)
entries=[]
for code, size, filename in [('icp4',16,'16x16'),('icp5',32,'32x32'),('icp6',64,'32x32@2x'),('ic07',128,'128x128'),('ic08',256,'256x256'),('ic09',512,'512x512'),('ic10',1024,'512x512@2x'),('ic11',32,'16x16@2x'),('ic12',64,'32x32@2x'),('ic13',256,'128x128@2x'),('ic14',512,'256x256@2x')]:
    dest=folder / f'icon_{filename}.png'
    subprocess.run(['sips','-z',str(size),str(size),str(root/'assets/AppIcon.png'),'--out',str(dest)],check=True,stdout=subprocess.DEVNULL)
    data=dest.read_bytes()
    entries.append(code.encode()+struct.pack('!I',len(data)+8)+data)
payload=b''.join(entries)
(root/'assets/AppIcon.icns').write_bytes(b'icns'+struct.pack('!I',len(payload)+8)+payload)
