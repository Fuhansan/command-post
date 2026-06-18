/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        ink: '#1F2937',       // 主文字
        sub: '#6B7280',       // 次文字
        faint: '#9CA3AF',     // 浅灰
        line: '#E5E7EB',      // 描边
        panel: '#F6F7F9',     // 侧栏底
        brand: '#2563EB',     // 主蓝
        selbg: '#EFF4FE',     // 选中底
        selborder: '#A5C8F5', // 选中边
      },
    },
  },
  plugins: [],
}
