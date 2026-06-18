import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// base: './' —— 产物用相对路径,WKWebView 以 file:// 加载也能找到资源。
export default defineConfig({
  plugins: [react()],
  base: './',
  build: { outDir: 'dist', emptyOutDir: true },
})
