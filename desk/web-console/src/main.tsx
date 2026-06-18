import React from 'react'
import ReactDOM from 'react-dom/client'
import '@fontsource-variable/hanken-grotesk'
import '@fontsource/jetbrains-mono/400.css'
import '@fontsource/jetbrains-mono/500.css'
import App from './App'
import './index.css'
import 'highlight.js/styles/github.css'
import { ready } from './bridge'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)

// 首屏渲染后通知 Swift 推全量状态。
ready()
