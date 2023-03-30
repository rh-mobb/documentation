#!/usr/bin/env python
# coding:utf-8

import os
import re
import yaml
import pandoc
from pandoc.types import *
from datetime import datetime
import argparse

__author__ = 'coderzh'

try:
  basestring
except NameError:
  basestring = str

class MyDumper(yaml.Dumper):
    def increase_indent(self, flow=False, indentless=False):
        return super(MyDumper, self).increase_indent(flow, False)

content_regex = re.compile(r'---([\s\S]*?)---([\s\S]*)')

replace_regex_list = [
#    (re.compile(r'^```(.*?)\n(.*?)\n```', re.DOTALL), r'{{< highlight \1 >}}\n\2\n{{< /highlight >}}'),
    (re.compile(r'<!--\smore\s-->'), '<!--more-->'),
    (re.compile(r'\{%\sraw\s%\}(.*)\{%\sendraw\s%\}'), r'\1')
]

def convert_front_matter(front_data, post_date, title):
    # front_data['url'] = url
    front_data['date'] = post_date
    front_data['title'] = title

    if 'layout' in front_data:
        del front_data['layout']

    for tag in ['tags', 'categories', 'category']:
        if tag in front_data and isinstance(front_data[tag], basestring):
            front_data[tag] = front_data[tag].split(' ')

    if 'category' in front_data:
        front_data['categories'] = front_data['category']
        del front_data['category']


def convert_body_text(body_text):
    result = body_text
    for regex, replace_with in replace_regex_list:
        result = regex.sub(replace_with, result)

    return result


def write_out_file(front_data, body_text, out_file_path):
    out_lines = []
    if front_data != '':
        out_lines = ['---']
        front_string = yaml.dump(front_data, width=1000, default_flow_style=False, allow_unicode=True, Dumper=MyDumper)
        out_lines.extend(front_string.splitlines())
        out_lines.append('---')
    out_lines.extend(body_text.splitlines())

    with open(out_file_path, 'w') as f:
        f.write('\n'.join(out_lines))


filename_regex = re.compile(r'(\d+-\d+-\d+)-(.*)')


def parse_from_filename(filename):
    slug = os.path.splitext(filename)[0]
    m = filename_regex.match(slug)
    if m:
        slug = m.group(2)
        post_date = datetime.strptime(m.group(1), '%Y-%m-%d')
        return post_date, '/%s/%s/' % (post_date.strftime('%Y/%m/%d'), slug)
    return None, '/' + slug

def get_title(content):
    title = 'Untitled document'
    md = pandoc.read(content)
    blocks = md[1]
    header = blocks[0]
    title_inlines = header[2]
    title = pandoc.write(title_inlines).strip()

    # for elt in pandoc.iter(content):
    #     if isinstance(elt, Header):
    #         title = pandoc.write(elt[-1]).strip()
    print(title)
    return title


def convert_post(file_path, out_dir):
    filename = os.path.basename(file_path)
    # post_date, url = parse_from_filename(filename)
    file_date = datetime.utcfromtimestamp(os.path.getmtime(file_path))
    post_date = file_date.isoformat()

    content = ''
    with open(file_path, 'r') as f:
        content = f.read()

    m = content_regex.match(content)
    if m:
        front_data = yaml.load(m.group(1), Loader=yaml.UnsafeLoader)
        body_text = convert_body_text(m.group(2))
    else:
        front_data = dict()
        body_text = convert_body_text(content)
    title = get_title(content)
    convert_front_matter(front_data, post_date, title)

    if not os.path.exists(out_dir):
        os.makedirs(out_dir)
        # write _index.md
        parent_dir = os.path.dirname(os.path.normpath(out_dir))
        dir = os.path.basename(os.path.normpath(parent_dir))
        index_md = """
---
title: "MOBB Docs and Guides - %s"
date: 2022-09-14
description: MOBB Docs and Guides for %s
archetype: chapter
---

MOBB Docs and Guides for %s
""" % (dir, dir, dir)
        _index_file_path = os.path.join(parent_dir, '_index.md')
        if not os.path.exists(_index_file_path):
            write_out_file("", index_md, _index_file_path)

    if filename == 'README.md':
        filename = '_index.md'
    out_file_path = os.path.join(out_dir, filename)

    write_out_file(front_data, body_text, out_file_path)

    return True


def convert(src_dir, out_dir):
    count = 0
    error = 0
    for root, dirs, files in os.walk(src_dir):
        for filename in files:
            try:
                if os.path.splitext(filename)[1] != '.md' or filename in ['LICENSE.md']:
                    continue
                file_path = os.path.join(root, filename)
                common_prefix = os.path.commonprefix([src_dir, file_path])
                rel_path = os.path.relpath(os.path.dirname(file_path), common_prefix)
                real_out_dir = os.path.join(out_dir, rel_path)
                # if filename == 'README.md':
                #     dirname = os.path.dirname(real_out_dir)
                #     real_out_dir = os.path.join(dirname, 'index.md')

                if convert_post(file_path, real_out_dir):
                    print('Converted: %s' % file_path)
                    count += 1
                else:
                    error += 1
            except Exception as e:
                error += 1
                print('Error convert: %s \nException: %s' % (file_path, e))

    print('--------\n%d file converted! %s' % (count, 'Error count: %d' % error if error > 0 else 'Congratulation!!!'))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Convert Jekyll blog to GoHugo')
    parser.add_argument('src_dir', help='jekyll post dir')
    parser.add_argument('out_dir', help='hugo root path')
    args = parser.parse_args()

    convert(os.path.abspath(args.src_dir), os.path.abspath(args.out_dir))
