export {};

declare global {
  interface Window {
    pbjs: {
      windowName: string;
      invoke: (
        windowName: string,
        name: string,
        params?: any,
        data?: any
      ) => Promise<any>;
      invokeAll: (name: string, params?: any, data?: any) => Promise<any[]>;
      handle: (
        windowName: string,
        name: string,
        handler: (event: any, params: any, data: any) => void
      ) => void;
      handleAll: (
        name: string,
        handler: (event: any, params: any, data: any) => void
      ) => void;
      removeHandler: (windowName: string, name: string) => void;
      removeAllHandlers: () => void;
    };

    pbjsHandleMessage: (messageJson: string) => void;
    pbjsHandleResponse: (responseJson: string) => void;
    pbjsSetGetAllExpectedCount: (requestId: number, count: number) => void;
    pbjsBridgeReady: boolean;
  }
}
