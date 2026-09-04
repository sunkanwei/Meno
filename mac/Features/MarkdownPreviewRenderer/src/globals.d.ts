interface Window {
  renderMarkdown(markdown: string): Promise<void>;
  webkit?: {
    messageHandlers?: Record<string, { postMessage(value: unknown): void }>;
  };
}
