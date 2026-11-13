import React from 'react';
import ReactDOM from 'react-dom/client';
import { App } from './App';
import './index.css';

// One shell for every screen; App picks the screen from the path (/, /feed, /dashboard, /dialog).
ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
