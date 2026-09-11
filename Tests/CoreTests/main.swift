//
//  main.swift — 测试入口
//
//  运行:swift run CoreTests
//

import Foundation

let code = TinyTestRunner.run(allSuites)

fflush(stdout)
exit(code)
