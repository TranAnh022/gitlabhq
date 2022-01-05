import React from 'react'
import '../App.scss';
const ImageBrowser = (props) => {
    return (
        <div className="picture">
            <img src={props.image} alt="Picture" style={{width:"95%"} }/>
        </div>
    )
}

export default ImageBrowser
