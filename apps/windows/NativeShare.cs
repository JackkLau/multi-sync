using System.Runtime.InteropServices;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using WinRT;

namespace MultiSync.Windows;

internal sealed class NativeShare
{
    [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDataTransferManagerInterop
    {
        IntPtr GetForWindow(IntPtr window, ref Guid id);
        void ShowShareUIForWindow(IntPtr window);
    }
    private DataTransferManager? _manager;
    private StorageFile? _file;
    private string _title = "MultiSync";
    public void Show(IntPtr window, StorageFile file, string title)
    {
        var interop = DataTransferManager.As<IDataTransferManagerInterop>();
        if (_manager is null)
        {
            var iid = new Guid("a5caee9b-8708-49d1-8d36-67d25a8da00c");
            var pointer = interop.GetForWindow(window, ref iid);
            try { _manager = MarshalInterface<DataTransferManager>.FromAbi(pointer); }
            finally { Marshal.Release(pointer); }
            _manager.DataRequested += (_, args) => {
                args.Request.Data.Properties.Title = _title;
                args.Request.Data.RequestedOperation = DataPackageOperation.Copy;
                if (_file is not null) args.Request.Data.SetStorageItems(new[] { _file });
            };
        }
        _file = file; _title = title;
        interop.ShowShareUIForWindow(window);
    }
}
