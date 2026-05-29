// ESLint flat config (v9+).
const js = require('@eslint/js');

module.exports = [
  js.configs.recommended,
  {
    files: ['**/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'commonjs',
      globals: {
        process: 'readonly',
        require: 'readonly',
        module: 'readonly',
        __dirname: 'readonly',
        Buffer: 'readonly',
        console: 'readonly',
        setTimeout: 'readonly',
        clearTimeout: 'readonly',
        setImmediate: 'readonly',
        setInterval: 'readonly',
        clearInterval: 'readonly',
        // Node 18+ web APIs
        AbortController: 'readonly',
        FormData: 'readonly',
        Blob: 'readonly',
        // `fetch` —— production 全 axios,但 test 文件(`rate-limit.test.js` /
        // `transcription.test.js`)用 Node 内置 fetch 驱动 HTTP。删这一行会让 npm run lint
        // 在 test 文件里报 3 个 no-undef(2026-05-15 codex review 抓住了我误删)。
        fetch: 'readonly',
      },
    },
    rules: {
      'no-unused-vars': ['warn', { argsIgnorePattern: '^_' }],
      'no-console': 'off',
      eqeqeq: ['error', 'always'],
      'prefer-const': 'warn',
      'no-var': 'error',
    },
  },
  {
    ignores: ['node_modules/**', 'coverage/**'],
  },
];
