// TypeScript module declarations for assets

declare module "*.wasm" {
  const wasmUrl: string;
  export default wasmUrl;
}

declare module "*.wasm?url" {
  const wasmUrl: string;
  export default wasmUrl;
}