//
//  Copied from from LogarithmicSlider.m and converted to macOS/Swift
//  Copyright (c) 2022 Jonathan Harris.
//
//  Created by Matt Kane on 19/01/2012.
//  Copyright (c) 2012 Matt Kane. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of
//  this software and associated documentation files (the "Software"), to deal in
//  the Software without restriction, including without limitation the rights to
//  use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
//  of the Software, and to permit persons to whom the Software is furnished to do
//  so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Cocoa

class LogarithmicSlider: NSSlider {

    // Range requested
    private var _minValue: Double = 0
    private var _maxValue: Double = 0

    // NSSlider superclass operates with log values
    // Override setters to log values
    // Override getters to convert back to linear

    override var minValue:Double {
        get {
            _minValue
        }
        set
        {
            super.minValue = log(_minValue)
            _minValue = newValue
        }
    }

    override var maxValue: Double {
        get {
            _maxValue
        }
        set
        {
            super.doubleValue = log(_maxValue)
            _maxValue = newValue
        }
    }

    override var doubleValue: Double {
        get {
            // This works around rounding errors.
            if super.doubleValue == super.maxValue {
                return _maxValue
            }
            else if super.doubleValue == super.minValue {
                return _minValue
            }
            else {
                return exp(super.doubleValue)
            }
        }
        set {
            super.doubleValue = log(newValue)
        }
    }

    override var floatValue: Float {
        get {
            Float(doubleValue)
        }
        set {
            doubleValue = Double(newValue)
        }
    }

    override var intValue: Int32 {
        get {
            Int32(round(doubleValue))
        }
        set {
            doubleValue = Double(newValue)
        }
    }

    override var integerValue: Int {
        get {
            Int(round(doubleValue))
        }
        set {
            doubleValue = Double(newValue)
        }
    }

    override var stringValue: String {
        get {
            String(doubleValue)
        }
        set {
            doubleValue = Double(newValue)!
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        super.doubleValue = log(super.doubleValue)

        _maxValue = super.maxValue
        super.maxValue = log(_maxValue)

        _minValue = super.minValue
        super.minValue = log(_minValue)
    }
}
