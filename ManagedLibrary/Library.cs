using System;
using System.Runtime.InteropServices;

namespace ManagedLibrary
{
    public class Library
    {
        // This is the static method we want to call from C++.
        // We use UnmanagedCallersOnly to make it callable from native code.
        [UnmanagedCallersOnly(EntryPoint = "say_hello")]
        public static void SayHello()
        {
            Console.WriteLine("Hello from C#!");
        }
    }
}