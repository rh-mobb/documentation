#!/usr/bin/env python
# coding:utf-8

import os
import shutil

src_dir = 'docs'
out_dir = 'content/docs'

def walk_docs():
    for root, dirs, files in os.walk(src_dir):
        for filename in files:
            try:
                if os.path.splitext(filename)[1] == '.md':
                    continue
                file_path = os.path.join(root, filename)
                common_prefix = os.path.commonprefix([src_dir, file_path])
                rel_path = os.path.relpath(os.path.dirname(file_path), common_prefix)
                real_out_dir = os.path.join(out_dir, rel_path)
                out_file_path = os.path.join(real_out_dir, filename)

                if not os.path.exists(real_out_dir):
                    print('mkdir %s' % real_out_dir)
                    os.makedirs(real_out_dir)
                if not os.path.exists(out_file_path):
                    print('mv %s %s' % (file_path, out_file_path))
                    shutil.copy2(file_path, out_file_path)

            except Exception as e:
                error += 1
                print('Error convert: %s \nException: %s' % (file_path, e))


if __name__ == '__main__':
    walk_docs()
