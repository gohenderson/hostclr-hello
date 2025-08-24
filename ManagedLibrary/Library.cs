// ManagedLibrary/Library.cs
using System;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;

namespace ManagedLibrary
{
    public static class Library
    {
        // Install the resolver as soon as the assembly loads.
        [ModuleInitializer]
        internal static void Init()
        {
            NativeLibrary.SetDllImportResolver(typeof(Library).Assembly, (name, asm, path) =>
            {
                if (name == "__Internal")
                {
                    // Map "__Internal" to the current process on Linux (dlopen(NULL, ...))
                    return dlopen(null, RTLD_NOW | RTLD_GLOBAL);
                }
                return IntPtr.Zero; // Defer to default
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
            Console.WriteLine($"C# called C++: 4 + 5 = {AddNumbers(4, 5)}");
        }
    }
}
