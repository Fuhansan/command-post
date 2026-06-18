/** @type {import('tailwindcss').Config} */
export default {
  darkMode: ['selector', '[data-theme="dark"]'],
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['"Geist Variable"', '"PingFang SC"', '-apple-system', 'BlinkMacSystemFont', 'sans-serif'],
        mono: ['"Geist Mono Variable"', 'ui-monospace', 'SFMono-Regular', 'monospace'],
      },
      // 全部指向 CSS 变量 → 切换 data-theme 即自动换肤
      colors: {
        bg: 'var(--bg)',
        elev: 'var(--bg-elev)',
        elev2: 'var(--bg-elev2)',
        sunken: 'var(--bg-sunken)',
        ink: 'var(--text)',
        dim: 'var(--text-dim)',
        faint: 'var(--text-faint)',
        line: 'var(--border)',
        strong: 'var(--border-strong)',
        accent: 'var(--accent)',
        accentfg: 'var(--accent-fg)',
        accentsoft: 'var(--accent-soft)',
        ok: 'var(--green)',
        warn: 'var(--amber)',
        bad: 'var(--red)',
      },
      boxShadow: {
        card: '0 1px 2px rgba(20,21,26,0.04), 0 1px 3px rgba(20,21,26,0.03)',
        pop: '0 12px 32px rgba(0,0,0,0.16)',
      },
    },
  },
  plugins: [],
}
