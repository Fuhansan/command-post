/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['"Hanken Grotesk Variable"', '-apple-system', 'BlinkMacSystemFont', '"PingFang SC"', 'sans-serif'],
        mono: ['"JetBrains Mono"', 'ui-monospace', 'SFMono-Regular', 'monospace'],
      },
      colors: {
        ink: '#14151A',       // 近黑(略暖)
        sub: '#6A6E78',       // 次文字
        faint: '#9CA0AB',     // 浅灰
        line: '#E7E8EC',      // 描边
        panel: '#F4F5F7',     // 侧栏底
        bg: '#FBFBFC',        // 内容底(近白略冷)
        brand: '#2563EB',     // 主蓝
        selbg: '#EEF3FE',     // 选中底
        selborder: '#B6CDFb', // 选中边
      },
      boxShadow: {
        card: '0 1px 2px rgba(20,21,26,0.04), 0 1px 3px rgba(20,21,26,0.03)',
        pop: '0 8px 28px rgba(20,21,26,0.12)',
      },
      keyframes: {
        rise: { '0%': { opacity: '0', transform: 'translateY(6px)' }, '100%': { opacity: '1', transform: 'translateY(0)' } },
      },
      animation: {
        rise: 'rise .28s cubic-bezier(.2,.7,.2,1) both',
      },
    },
  },
  plugins: [],
}
