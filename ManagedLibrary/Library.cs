using System;
using System.Runtime.InteropServices;

namespace ManagedLibrary
{
    public class Library
    {
        // Install early, before any P/Invoke to "__Internal"
        static Library()
        {
            NativeLibrary.SetDllImportResolver(typeof(Library).Assembly, (name, asm, path) =>
            {
                if (name == "__Internal")
                {
                    // Get handle to the main program (current process)
                    return dlopen(null, RTLD_NOW | RTLD_GLOBAL);
                }
                return IntPtr.Zero;
            });
        }

        private const int RTLD_NOW = 2;
        private const int RTLD_GLOBAL = 0x100;

        [DllImport("libdl.so.2", EntryPoint = "dlopen")]
        private static extern IntPtr dlopen(string? file, int flags);

        [DllImport("__Internal", EntryPoint = "add_numbers", CallingConvention = CallingConvention.Cdecl)]
        private static extern int AddNumbers(int a, int b);

        [UnmanagedCallersOnly(EntryPoint = "say_hello")]
        public static void SayHello()
        {
            Console.WriteLine("Hello from C#!");
            Console.WriteLine($"C# called C++: 4 + 5 = {AddNumbers(4,5)}");
        }
    }
}
