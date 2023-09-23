// Import rollup plugins
import resolve from '@rollup/plugin-node-resolve';
import { terser } from 'rollup-plugin-terser';
import css from 'rollup-plugin-import-css';
import del from 'rollup-plugin-delete';
import copy from 'rollup-plugin-copy';

export default {
  plugins: [
    // Resolve bare module specifiers to relative paths
    resolve(),
    terser({
      ecma: 2020,
      module: true,
      warnings: true,
    }),
    // Get any CSS in JS imports
    css(),
    // Remove old dist directory
    del({
      targets: [
        './themes/rhds/static/js/rhds',
      ],
    }),
    copy({ targets: 
      [
        { src: 'node_modules/@patternfly/icons/fas/*', dest: 'themes/rhds/static/js/rhds/icons/fas' },
        { src: 'node_modules/@patternfly/icons/far/*', dest: 'themes/rhds/static/js/rhds/icons/far' },
        { src: 'node_modules/@patternfly/icons/fab/*', dest: 'themes/rhds/static/js/rhds/icons/fab' },
        { src: 'node_modules/@patternfly/icons/patternfly/*', dest: 'themes/rhds/static/js/rhds/icons/patternfly' },
        { src: 'node_modules/@rhds/elements/**/*-lightdom.css', dest: 'themes/rhds/static/css/rhds/' }
      ]
    }),
  ],
  // Single bundle example
  input: 'themes/rhds/assets/js/elements/import.js',
  output: [{
    dir: 'themes/rhds/static/js/rhds/',
    entryFileNames: 'bundle.js',
    chunkFileNames: 'bundle-chunk.js',
    format: 'esm'
  }],
  preserveEntrySignatures: 'strict',
};