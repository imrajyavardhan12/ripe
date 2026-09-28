import RipeCLI

@main
enum Entry {
    static func main() async {
        await RootCommand.main()
    }
}
