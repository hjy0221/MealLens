"""Create a hard-linked training view with ASCII class paths for Create ML.

The model metadata carries a reversible map back to the original Korean labels.
"""
import argparse
import json
import os
from pathlib import Path

def prepare(source, destination):
    destination.mkdir(parents=True,exist_ok=False)
    manifest=json.loads((source/'manifest.json').read_text())
    labels=sorted({r['label'] for r in manifest['records']})
    mapping={label: ('aihub_korea__k%03d'%index if not label.isascii() else label) for index,label in enumerate(labels)}
    for record in manifest['records']:
        old=record['prepared'];label=mapping[record['label']]
        new=f"{record['split']}/{label}/{Path(old).name}"
        target=destination/new;target.parent.mkdir(parents=True,exist_ok=True)
        os.link(source/old,target)
        record['original_label']=record['label'];record['label']=label;record['prepared']=new
    (destination/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
    (destination/'class-labels.json').write_text(json.dumps({v:k for k,v in mapping.items()},ensure_ascii=False))
    print('Prepared ASCII class paths:',len(labels),len(manifest['records']),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('destination',type=Path)
    a=p.parse_args();prepare(a.source,a.destination)
