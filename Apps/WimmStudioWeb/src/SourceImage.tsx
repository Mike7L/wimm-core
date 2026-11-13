import { useEffect, useRef, useState } from 'react';
import { RotateCcw, RotateCw } from 'lucide-react';

const storageKey = (path: string) => `wimm.photo.rotation:${path}`;
const rotationEvent = 'wimm-photo-rotation';

function savedRotation(path: string): number {
  try {
    const value = Number(localStorage.getItem(storageKey(path)));
    return [0, 90, 180, 270].includes(value) ? value : 0;
  } catch {
    return 0;
  }
}

// A separate frame reserves the rotated bounds: CSS transforms alone clip
// portrait photos and leave the following content in the unrotated position.
export function SourceImage({ path, alt, thumbnail = false }: {
  path: string;
  alt: string;
  thumbnail?: boolean;
}) {
  const [rotation, setRotation] = useState(() => savedRotation(path));
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [availableWidth, setAvailableWidth] = useState(0);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const sync = () => setRotation(savedRotation(path));
    sync();
    window.addEventListener('storage', sync);
    window.addEventListener(rotationEvent, sync);
    return () => {
      window.removeEventListener('storage', sync);
      window.removeEventListener(rotationEvent, sync);
    };
  }, [path]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const observer = new ResizeObserver(([entry]) => setAvailableWidth(entry.contentRect.width));
    observer.observe(container);
    return () => observer.disconnect();
  }, []);

  function turn(delta: number) {
    const next = (rotation + delta + 360) % 360;
    try {
      localStorage.setItem(storageKey(path), String(next));
    } catch {
      // Rotation still works when browser storage is unavailable.
    }
    window.dispatchEvent(new Event(rotationEvent));
    setRotation(next);
  }

  const sideways = rotation === 90 || rotation === 270;
  const width = sideways ? size.height : size.width;
  const height = sideways ? size.width : size.height;
  const scale = width && height
    ? Math.min(1, (availableWidth || (thumbnail ? 176 : 600)) / width, (thumbnail ? 96 : 384) / height)
    : 1;

  return (
    <div ref={containerRef} className={thumbnail ? 'w-40 max-w-full' : 'w-full'}>
      {!thumbnail && (
        <div className="mb-2 flex justify-end gap-1">
          <button type="button" onClick={() => turn(-90)} title="Повернуть влево"
            aria-label="Повернуть фото влево" className="rounded p-2 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100">
            <RotateCcw className="h-4 w-4" aria-hidden="true" />
          </button>
          <button type="button" onClick={() => turn(90)} title="Повернуть вправо"
            aria-label="Повернуть фото вправо" className="rounded p-2 text-zinc-400 hover:bg-zinc-800 hover:text-zinc-100">
            <RotateCw className="h-4 w-4" aria-hidden="true" />
          </button>
        </div>
      )}
      <div className="relative mx-auto overflow-hidden rounded" style={{
        width: width ? width * scale : '100%',
        height: height ? height * scale : (thumbnail ? 96 : 200),
      }}>
        <img src={`/api/media?path=${encodeURIComponent(path)}`} alt={alt} loading="lazy"
          onLoad={(event) => setSize({ width: event.currentTarget.naturalWidth, height: event.currentTarget.naturalHeight })}
          className="absolute max-w-none" style={{
            width: size.width ? size.width * scale : '100%',
            height: size.height ? size.height * scale : 'auto',
            left: '50%', top: '50%',
            transform: `translate(-50%, -50%) rotate(${rotation}deg)`,
          }} />
      </div>
    </div>
  );
}
