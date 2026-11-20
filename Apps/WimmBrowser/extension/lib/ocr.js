const local = path => chrome.runtime.getURL('vendor/' + path);
let engine;

async function recognizeImage(image) {
  if (!engine) {
    const {default: Tesseract} = await import('../vendor/tesseract/tesseract.esm.min.js');
    engine = await Tesseract.createWorker(['rus', 'eng'], Tesseract.OEM.LSTM_ONLY, {
      workerPath: local('tesseract/worker.min.js'),
      corePath: local('tesseract/tesseract-core-lstm.js'),
      langPath: local('tesseract/languages'),
      cacheMethod: 'none', gzip: false, workerBlobURL: false,
      errorHandler: error => console.error(error)
    });
  }
  const {data} = await engine.recognize(image);
  return data.text.trim();
}

async function readPDF(blob) {
  const pdfjs = await import('../vendor/pdfjs/pdf.min.mjs');
  pdfjs.GlobalWorkerOptions.workerSrc = local('pdfjs/pdf.worker.min.mjs');
  const task = pdfjs.getDocument({
    data: new Uint8Array(await blob.arrayBuffer()), isEvalSupported: false,
    cMapUrl: local('pdfjs/cmaps/'), cMapPacked: true, standardFontDataUrl: local('pdfjs/standard_fonts/')
  });
  try {
    const pdf = await task.promise;
    const pages = [];
    for (let index = 1; index <= pdf.numPages; index++) {
      const page = await pdf.getPage(index);
      try {
        const content = await page.getTextContent();
        let text = content.items.filter(item => item.str !== undefined)
          .map(item => item.str + (item.hasEOL ? '\n' : ' ')).join('').trim();
        if (!text) {
          const size = page.getViewport({scale: 1});
          const scale = Math.min(3, 2800 / Math.max(size.width, size.height));
          const viewport = page.getViewport({scale});
          const canvas = document.createElement('canvas');
          canvas.width = Math.ceil(viewport.width);
          canvas.height = Math.ceil(viewport.height);
          try {
            // Offscreen documents have no animation frames. Print rendering runs independently.
            await page.render({canvasContext: canvas.getContext('2d'), viewport, intent:'print'}).promise;
            text = await recognizeImage(canvas);
          } finally {
            canvas.width = canvas.height = 0;
          }
        }
        if (text) pages.push(text);
      } finally {
        page.cleanup();
      }
    }
    return pages.join('\n\n');
  } finally {
    await task.destroy();
  }
}

export async function readAttachment(note) {
  if (note.kind === 'pdf') return readPDF(note.blob);
  // Decode through the browser so GIF and WebP use the same OCR input as screenshots.
  const bitmap = await createImageBitmap(note.blob);
  try {
    const canvas = document.createElement('canvas');
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = 'white';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(bitmap, 0, 0);
    return await recognizeImage(canvas);
  } finally {
    bitmap.close();
  }
}
